package main

import (
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
	log.Println("Go HTTP/1.1 server on :9081")
	log.Fatal(http.ListenAndServe(":9081", nil))
}
