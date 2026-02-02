package main

import (
	"crypto/tls"
	"fmt"
	"log"
	"net/http"
	"runtime"
)

func handler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	fmt.Fprint(w, "Hello, World!")
}

func main() {
	runtime.GOMAXPROCS(runtime.NumCPU())
	http.HandleFunc("/", handler)

	server := &http.Server{
		Addr: ":9443",
		TLSConfig: &tls.Config{
			NextProtos: []string{"h2", "http/1.1"},
		},
	}

	log.Println("Go HTTP/2 server on :9443")
	log.Fatal(server.ListenAndServeTLS("cert.pem", "key.pem"))
}
