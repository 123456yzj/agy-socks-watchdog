package main

import (
	"bytes"
	"errors"
	"io"
	"net"
	"testing"
	"time"
)

func TestReadGreeting(t *testing.T) {
	for _, tc := range []struct {
		name string
		data []byte
		fail bool
	}{
		{"no authentication", []byte{5, 1, 0}, false},
		{"multiple methods", []byte{5, 2, 0, 2}, false},
		{"wrong version", []byte{4, 1, 0}, true},
		{"no methods", []byte{5, 0}, true},
		{"truncated", []byte{5, 2, 0}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := readGreeting(bytes.NewReader(tc.data))
			if (err != nil) != tc.fail {
				t.Fatalf("error = %v, want failure %v", err, tc.fail)
			}
			if !tc.fail && !bytes.Equal(got, tc.data) {
				t.Fatalf("got %v, want %v", got, tc.data)
			}
		})
	}
}

func TestReadSOCKS5Message(t *testing.T) {
	for _, tc := range []struct {
		name string
		data []byte
		fail bool
	}{
		{"IPv4", []byte{5, 1, 0, 1, 127, 0, 0, 1, 1, 187}, false},
		{"domain", []byte{5, 1, 0, 3, 3, 'a', '.', 'b', 1, 187}, false},
		{"IPv6", append([]byte{5, 1, 0, 4}, make([]byte, 18)...), false},
		{"wrong version", []byte{4, 1, 0, 1}, true},
		{"wrong address type", []byte{5, 1, 0, 9}, true},
		{"truncated IPv4", []byte{5, 1, 0, 1, 127}, true},
		{"missing domain length", []byte{5, 1, 0, 3}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := readSOCKS5Message(bytes.NewReader(tc.data))
			if (err != nil) != tc.fail {
				t.Fatalf("error = %v, want failure %v", err, tc.fail)
			}
			if !tc.fail && !bytes.Equal(got, tc.data) {
				t.Fatalf("got %v, want %v", got, tc.data)
			}
		})
	}
}

func expectBytes(r io.Reader, want []byte) error {
	got := make([]byte, len(want))
	if _, err := io.ReadFull(r, got); err != nil {
		return err
	}
	if !bytes.Equal(got, want) {
		return errors.New("unexpected forwarded bytes")
	}
	return nil
}

func TestHandleConnectionForwardsHandshakeAndTraffic(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	greeting := []byte{5, 1, 0}
	method := []byte{5, 0}
	request := []byte{5, 1, 0, 3, 3, 'a', '.', 'b', 1, 187}
	reply := []byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 80}
	upload := []byte("client payload")
	download := []byte("server payload")
	upstreamDone := make(chan error, 1)
	go func() {
		upstreamDone <- func() error {
			conn, err := listener.Accept()
			if err != nil {
				return err
			}
			defer conn.Close()
			_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
			if err := expectBytes(conn, greeting); err != nil {
				return err
			}
			if err := writeAll(conn, method); err != nil {
				return err
			}
			if err := expectBytes(conn, request); err != nil {
				return err
			}
			if err := writeAll(conn, reply); err != nil {
				return err
			}
			if err := expectBytes(conn, upload); err != nil {
				return err
			}
			return writeAll(conn, download)
		}()
	}()
	client, proxy := net.Pipe()
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(3 * time.Second))
	done := make(chan struct{})
	go func() {
		handleConnection(1, proxy, listener.Addr().String(), time.Second)
		close(done)
	}()
	for _, step := range []struct {
		write bool
		data  []byte
	}{
		{true, greeting}, {false, method}, {true, request},
		{false, reply}, {true, upload}, {false, download},
	} {
		if step.write {
			err = writeAll(client, step.data)
		} else {
			err = expectBytes(client, step.data)
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	if err := <-upstreamDone; err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("connection handler did not exit after upstream closed")
	}
}

func TestRelayClosesIdleTunnel(t *testing.T) {
	client, clientProxy := net.Pipe()
	upstreamProxy, upstream := net.Pipe()
	defer client.Close()
	defer upstream.Close()
	done := make(chan struct{})
	go func() {
		relay(2, clientProxy, upstreamProxy, 80*time.Millisecond)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("idle tunnel was not closed")
	}
	if _, err := client.Read(make([]byte, 1)); !errors.Is(err, io.EOF) {
		t.Fatalf("client read error = %v, want EOF", err)
	}
}

func TestRelayActivityRefreshesIdleTimeout(t *testing.T) {
	client, clientProxy := net.Pipe()
	upstreamProxy, upstream := net.Pipe()
	defer client.Close()
	defer upstream.Close()
	_ = client.SetDeadline(time.Now().Add(5 * time.Second))
	_ = upstream.SetDeadline(time.Now().Add(5 * time.Second))
	done := make(chan struct{})
	go func() {
		relay(3, clientProxy, upstreamProxy, 500*time.Millisecond)
		close(done)
	}()
	for i := 0; i < 5; i++ {
		// Total activity exceeds one idle interval; both directions refresh it.
		time.Sleep(150 * time.Millisecond)
		writer, reader := client, upstream
		if i%2 != 0 {
			writer, reader = upstream, client
		}
		written := make(chan error, 1)
		go func() { written <- writeAll(writer, []byte("ping")) }()
		if err := expectBytes(reader, []byte("ping")); err != nil {
			t.Fatalf("active tunnel closed on iteration %d: %v", i, err)
		}
		if err := <-written; err != nil {
			t.Fatal(err)
		}
	}
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("tunnel did not close after traffic stopped")
	}
}

type shortWriter struct{ bytes.Buffer }

func (w *shortWriter) Write(data []byte) (int, error) {
	if len(data) > 2 {
		data = data[:2]
	}
	return w.Buffer.Write(data)
}

func TestWriteAllHandlesShortWrites(t *testing.T) {
	var w shortWriter
	if err := writeAll(&w, []byte("hello world")); err != nil {
		t.Fatal(err)
	}
	if got := w.String(); got != "hello world" {
		t.Fatalf("got %q", got)
	}
}
