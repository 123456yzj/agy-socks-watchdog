package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var connectionID atomic.Uint64

func main() {
	listenAddr := flag.String("listen", "127.0.0.1:18080", "local SOCKS5 listen address")
	upstreamAddr := flag.String("upstream", "127.0.0.1:10808", "upstream SOCKS5 address")
	idleTimeout := flag.Duration("idle-timeout", 25*time.Second, "close tunnels with no traffic in either direction")
	logPath := flag.String("log", "", "append logs to this file")
	flag.Parse()

	if *idleTimeout <= 0 {
		log.Fatal("idle-timeout must be greater than zero")
	}
	if *logPath != "" {
		f, err := os.OpenFile(*logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err != nil {
			log.Fatalf("open log: %v", err)
		}
		defer f.Close()
		log.SetOutput(f)
	}

	listener, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		log.Fatal(err)
	}
	defer listener.Close()
	log.Printf("listening on %s, upstream %s, idle timeout %s", *listenAddr, *upstreamAddr, *idleTimeout)

	for {
		client, err := listener.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		id := connectionID.Add(1)
		go handleConnection(id, client, *upstreamAddr, *idleTimeout)
	}
}

func handleConnection(id uint64, client net.Conn, upstreamAddr string, idleTimeout time.Duration) {
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(10 * time.Second))

	upstream, err := net.DialTimeout("tcp", upstreamAddr, 5*time.Second)
	if err != nil {
		log.Printf("[%d] connect upstream: %v", id, err)
		return
	}
	defer upstream.Close()
	_ = upstream.SetDeadline(time.Now().Add(10 * time.Second))

	if err := proxySOCKS5Handshake(client, upstream); err != nil {
		log.Printf("[%d] SOCKS5 handshake: %v", id, err)
		return
	}

	log.Printf("[%d] tunnel opened", id)
	relay(id, client, upstream, idleTimeout)
}

func proxySOCKS5Handshake(client, upstream net.Conn) error {
	greeting, err := readGreeting(client)
	if err != nil {
		return err
	}
	if err := writeAll(upstream, greeting); err != nil {
		return err
	}
	method := make([]byte, 2)
	if _, err := io.ReadFull(upstream, method); err != nil {
		return err
	}
	if err := writeAll(client, method); err != nil {
		return err
	}
	if method[0] != 5 || method[1] == 0xff {
		return fmt.Errorf("upstream rejected authentication method: %v", method)
	}

	request, err := readSOCKS5Message(client)
	if err != nil {
		return err
	}
	if err := writeAll(upstream, request); err != nil {
		return err
	}
	reply, err := readSOCKS5Message(upstream)
	if err != nil {
		return err
	}
	if err := writeAll(client, reply); err != nil {
		return err
	}
	if len(reply) < 2 || reply[1] != 0 {
		return fmt.Errorf("upstream connect failed with reply code %d", reply[1])
	}
	return nil
}

func readGreeting(r io.Reader) ([]byte, error) {
	header := make([]byte, 2)
	if _, err := io.ReadFull(r, header); err != nil {
		return nil, err
	}
	if header[0] != 5 || header[1] == 0 {
		return nil, fmt.Errorf("invalid SOCKS5 greeting")
	}
	methods := make([]byte, int(header[1]))
	if _, err := io.ReadFull(r, methods); err != nil {
		return nil, err
	}
	return append(header, methods...), nil
}

func readSOCKS5Message(r io.Reader) ([]byte, error) {
	header := make([]byte, 4)
	if _, err := io.ReadFull(r, header); err != nil {
		return nil, err
	}
	if header[0] != 5 {
		return nil, fmt.Errorf("invalid SOCKS version %d", header[0])
	}

	var addressLength int
	switch header[3] {
	case 1:
		addressLength = 4
	case 3:
		length := make([]byte, 1)
		if _, err := io.ReadFull(r, length); err != nil {
			return nil, err
		}
		header = append(header, length[0])
		addressLength = int(length[0])
	case 4:
		addressLength = 16
	default:
		return nil, fmt.Errorf("unsupported address type %d", header[3])
	}

	tail := make([]byte, addressLength+2)
	if _, err := io.ReadFull(r, tail); err != nil {
		return nil, err
	}
	return append(header, tail...), nil
}

func relay(id uint64, client, upstream net.Conn, idleTimeout time.Duration) {
	var deadlineMu sync.Mutex
	touch := func() {
		deadlineMu.Lock()
		deadline := time.Now().Add(idleTimeout)
		_ = client.SetDeadline(deadline)
		_ = upstream.SetDeadline(deadline)
		deadlineMu.Unlock()
	}
	touch()

	errCh := make(chan error, 2)
	copyDirection := func(dst, src net.Conn) {
		buffer := make([]byte, 32*1024)
		for {
			n, readErr := src.Read(buffer)
			if n > 0 {
				touch()
				if err := writeAll(dst, buffer[:n]); err != nil {
					errCh <- err
					return
				}
				touch()
			}
			if readErr != nil {
				errCh <- readErr
				return
			}
		}
	}

	go copyDirection(upstream, client)
	go copyDirection(client, upstream)
	err := <-errCh
	_ = client.Close()
	_ = upstream.Close()
	<-errCh

	if isTimeout(err) {
		log.Printf("[%d] tunnel closed after %s idle", id, idleTimeout)
	} else if !errors.Is(err, io.EOF) && !strings.Contains(err.Error(), "use of closed network connection") {
		log.Printf("[%d] tunnel closed: %v", id, err)
	} else {
		log.Printf("[%d] tunnel closed", id)
	}
}

func writeAll(w io.Writer, data []byte) error {
	for len(data) > 0 {
		n, err := w.Write(data)
		if err != nil {
			return err
		}
		data = data[n:]
	}
	return nil
}

func isTimeout(err error) bool {
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Timeout()
}
