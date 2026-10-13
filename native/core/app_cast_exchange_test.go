package core

import (
	"net"
	"strconv"
	"strings"
	"testing"
	"time"
)

// 起一个真实的 UDP SSDP 应答器，验证 nativeCastExchange 能发出 M-SEARCH 并解析应答。
func TestNativeCastExchangeFindsResponder(t *testing.T) {
	server, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer server.Close()
	port := server.LocalAddr().(*net.UDPAddr).Port

	done := make(chan struct{})
	go func() {
		defer close(done)
		buffer := make([]byte, 2048)
		_ = server.SetReadDeadline(time.Now().Add(3 * time.Second))
		size, from, err := server.ReadFromUDP(buffer)
		if err != nil {
			return
		}
		if !strings.Contains(string(buffer[:size]), "M-SEARCH") {
			return
		}
		reply := "HTTP/1.1 200 OK\r\n" +
			"LOCATION: http://127.0.0.1:" + strconv.Itoa(port) + "/desc.xml\r\n" +
			"ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
		_, _ = server.WriteToUDP([]byte(reply), from)
	}()

	target := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port}
	found := nativeCastExchange([]*net.UDPAddr{target}, nativeCastSearchMessages(), 2*time.Second, nil)
	<-done
	if len(found) != 1 || !strings.HasSuffix(found[0], "/desc.xml") {
		t.Fatalf("expected one location, got %#v", found)
	}
}

// 搜索消息必须覆盖多种 ST，否则只应答 ssdp:all 的电视会搜不到。
func TestNativeCastSearchMessagesCoverCommonTypes(t *testing.T) {
	messages := nativeCastSearchMessages()
	joined := strings.Join(messages, "\n")
	for _, want := range []string{"ssdp:all", "upnp:rootdevice", "MediaRenderer", "AVTransport"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("search messages missing %q: %#v", want, messages)
		}
	}
	message := nativeCastMessage("ssdp:all")
	for _, want := range []string{"M-SEARCH * HTTP/1.1", "HOST: 239.255.255.250:1900", `MAN: "ssdp:discover"`, "ST: ssdp:all"} {
		if !strings.Contains(message, want) {
			t.Fatalf("M-SEARCH missing %q:\n%s", want, message)
		}
	}
	if !strings.HasSuffix(message, "\r\n\r\n") {
		t.Fatalf("M-SEARCH must end with a blank line, got %q", message)
	}
}

// 无法连接的设备描述抓取应安全返回失败，不 panic。
func TestNativeCastDescribeFailureIsIsolated(t *testing.T) {
	if _, ok := nativeCastDescribe(t.Context(), "http://127.0.0.1:1/desc.xml"); ok {
		t.Fatalf("unreachable location should not describe")
	}
}
