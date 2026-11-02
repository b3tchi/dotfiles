package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func frame(mtype uint32, payload string) []byte {
	buf := make([]byte, 0, 14+len(payload))
	buf = append(buf, "i3-ipc"...)
	buf = binary.LittleEndian.AppendUint32(buf, uint32(len(payload)))
	buf = binary.LittleEndian.AppendUint32(buf, mtype)
	return append(buf, payload...)
}

func TestScanFrames_DecodesEveryFrameAndItsType(t *testing.T) {
	stream := bytes.NewReader(bytes.Join([][]byte{
		frame(i3TypeRunCommand, "focus left"),
		frame(i3TypeSubscribe, `["mode"]`),
		frame(i3TypeRunCommand, "move left"),
	}, nil))

	var gotTypes []uint32
	var gotPayloads []string
	err := scanFrames(stream, func(mtype uint32, payload []byte) {
		gotTypes = append(gotTypes, mtype)
		gotPayloads = append(gotPayloads, string(payload))
	})
	if err != nil {
		t.Fatalf("scanFrames: %v", err)
	}
	wantTypes := []uint32{i3TypeRunCommand, i3TypeSubscribe, i3TypeRunCommand}
	wantPayloads := []string{"focus left", `["mode"]`, "move left"}
	if len(gotTypes) != len(wantTypes) {
		t.Fatalf("got %d frames %q, want %d", len(gotTypes), gotPayloads, len(wantTypes))
	}
	for i := range wantTypes {
		if gotTypes[i] != wantTypes[i] || gotPayloads[i] != wantPayloads[i] {
			t.Errorf("frame %d: got (%d,%q), want (%d,%q)", i, gotTypes[i], gotPayloads[i], wantTypes[i], wantPayloads[i])
		}
	}
}

func TestScanFrames_RejectsABadMagic(t *testing.T) {
	bad := append([]byte("XX-ipc"), make([]byte, 8)...)
	err := scanFrames(bytes.NewReader(bad), func(uint32, []byte) {})
	if err == nil {
		t.Error("a frame with the wrong magic was accepted")
	}
}

// The proxy is livecheck's answer to live_check.py's RecordingI3: the REAL
// daemon talks to the REAL i3, and every command it dispatches is recorded
// on the way through. A relay that dropped or reordered bytes would break
// the daemon it is observing, so this asserts both halves: the command
// reaches i3, and i3's reply reaches the daemon.
func TestI3Proxy_RelaysBothWaysAndRecordsCommands(t *testing.T) {
	dir := t.TempDir()
	upstreamPath := filepath.Join(dir, "up.sock")
	proxyPath := filepath.Join(dir, "proxy.sock")

	// A stand-in i3: records what it received, answers success.
	upstream, err := net.Listen("unix", upstreamPath)
	if err != nil {
		t.Fatalf("listen upstream: %v", err)
	}
	defer upstream.Close()

	p, err := StartI3Proxy(proxyPath, upstreamPath)
	if err != nil {
		t.Fatalf("StartI3Proxy: %v", err)
	}
	defer p.Close()

	// What the proxy had recorded at the moment i3 received the command:
	// recording happens BEFORE forwarding (kwi3-hoex.31), so it already
	// holds it - and so does every later read of Commands().
	gotUpstream := make(chan string, 4)
	recordedAtReceipt := make(chan []string, 4)
	go func() {
		conn, err := upstream.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_ = scanFrames(conn, func(mtype uint32, payload []byte) {
			recordedAtReceipt <- p.Commands()
			gotUpstream <- string(payload)
			conn.Write(frame(mtype, `[{"success":true}]`))
		})
	}()

	client, err := net.Dial("unix", proxyPath)
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer client.Close()

	if _, err := client.Write(frame(i3TypeRunCommand, "focus left")); err != nil {
		t.Fatalf("write: %v", err)
	}

	select {
	case got := <-gotUpstream:
		if got != "focus left" {
			t.Errorf("upstream saw %q, want %q", got, "focus left")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the proxy never forwarded the command to the upstream i3")
	}

	client.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 256)
	n, err := client.Read(buf)
	if err != nil {
		t.Fatalf("no reply relayed back to the client: %v", err)
	}
	if !bytes.Contains(buf[:n], []byte(`"success":true`)) {
		t.Errorf("reply %q does not carry i3's answer", buf[:n])
	}

	if got := <-recordedAtReceipt; len(got) != 1 || got[0] != "focus left" {
		t.Errorf("when i3 received the command the proxy had recorded %q, want [focus left]", got)
	}
	if got := p.Commands(); len(got) != 1 || got[0] != "focus left" {
		t.Errorf("proxy recorded %q, want [focus left]", got)
	}

	p.Reset()
	if got := p.Commands(); len(got) != 0 {
		t.Errorf("after Reset the proxy still holds %q", got)
	}
}

func TestI3Proxy_SocketPathIsCreatedAndRemoved(t *testing.T) {
	dir := t.TempDir()
	proxyPath := filepath.Join(dir, "p.sock")
	upstreamPath := filepath.Join(dir, "u.sock")
	up, err := net.Listen("unix", upstreamPath)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer up.Close()

	p, err := StartI3Proxy(proxyPath, upstreamPath)
	if err != nil {
		t.Fatalf("StartI3Proxy: %v", err)
	}
	if _, err := os.Stat(proxyPath); err != nil {
		t.Fatalf("proxy socket not created: %v", err)
	}
	p.Close()
	if _, err := os.Stat(proxyPath); !os.IsNotExist(err) {
		t.Errorf("proxy socket survived Close: %v", err)
	}
}

// The recorder decodes frames however the stream is cut: byte by byte, two
// frames in one write, a frame split across writes. A stream that is not
// i3 IPC stops the recording and never fails the write, so the relay it
// sits behind never sees an error.
func TestFrameRecorder_DecodesAcrossWritesAndNeverFails(t *testing.T) {
	stream := bytes.Join([][]byte{
		frame(i3TypeRunCommand, "focus left"),
		frame(i3TypeSubscribe, `["mode"]`),
		frame(i3TypeRunCommand, ""),
		frame(i3TypeRunCommand, "move right"),
	}, nil)
	for _, cut := range []int{1, 3, 14, 15, 24, len(stream)} {
		var got []string
		r := &frameRecorder{onFrame: func(mtype uint32, payload []byte) {
			got = append(got, fmt.Sprintf("%d:%s", mtype, payload))
		}}
		for i := 0; i < len(stream); i += cut {
			end := i + cut
			if end > len(stream) {
				end = len(stream)
			}
			if n, err := r.Write(stream[i:end]); err != nil || n != end-i {
				t.Fatalf("cut %d: Write = %d, %v", cut, n, err)
			}
		}
		want := []string{"0:focus left", `2:["mode"]`, "0:", "0:move right"}
		if fmt.Sprint(got) != fmt.Sprint(want) {
			t.Errorf("cut %d: frames %q, want %q", cut, got, want)
		}
	}

	var got []string
	r := &frameRecorder{onFrame: func(_ uint32, payload []byte) { got = append(got, string(payload)) }}
	bad := append(append([]byte("XX-ipc"), make([]byte, 8)...), frame(i3TypeRunCommand, "focus left")...)
	if n, err := r.Write(bad); err != nil || n != len(bad) {
		t.Fatalf("bad magic: Write = %d, %v, want %d, nil", n, err, len(bad))
	}
	if n, err := r.Write(frame(i3TypeRunCommand, "focus up")); err != nil || n == 0 {
		t.Fatalf("after a bad magic: Write = %d, %v", n, err)
	}
	if len(got) != 0 {
		t.Errorf("a stream with a bad magic recorded %q, want nothing", got)
	}
}
