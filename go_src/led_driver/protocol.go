package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
)

// Command represents an inbound IPC command from the Elixir port process.
type Command struct {
	Cmd string `json:"cmd"`

	// flight_card — unified command for the full 64×64 display
	Airline      string  `json:"airline,omitempty"`
	Flight       string  `json:"flight,omitempty"`
	Aircraft     string  `json:"aircraft,omitempty"`
	RouteOrigin  string  `json:"route_origin,omitempty"`
	RouteDest    string  `json:"route_dest,omitempty"`
	AltitudeFt   *int    `json:"altitude_ft,omitempty"`
	SpeedKt      *int    `json:"speed_kt,omitempty"`
	BearingDeg   *int    `json:"bearing_deg,omitempty"`
	VRateFpm     *int    `json:"vrate_fpm,omitempty"`
	DepTime      string  `json:"dep_time,omitempty"`
	ArrTime      string  `json:"arr_time,omitempty"`
	Progress     float64 `json:"progress,omitempty"`
	AirlineColor [3]int  `json:"airline_color,omitempty"`

	// qr command
	Data string `json:"data,omitempty"`

	// brightness command
	Value int `json:"value,omitempty"`

	// text command (raw debug rendering)
	X     int    `json:"x,omitempty"`
	Y     int    `json:"y,omitempty"`
	Text  string `json:"text,omitempty"`
	Color [3]int `json:"color,omitempty"`
}

// Response is written back to Elixir over stdout.
type Response struct {
	Status string `json:"status"`
	Error  string `json:"error,omitempty"`
}

// readMessage reads one length-prefixed JSON message from stdin.
// Format: 4-byte big-endian uint32 length, followed by that many bytes of JSON.
func readMessage(r io.Reader) ([]byte, error) {
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return nil, fmt.Errorf("reading length prefix: %w", err)
	}
	msgLen := binary.BigEndian.Uint32(lenBuf[:])
	if msgLen == 0 {
		return nil, fmt.Errorf("zero-length message")
	}
	if msgLen > 1<<20 { // 1 MiB sanity cap
		return nil, fmt.Errorf("message too large: %d bytes", msgLen)
	}
	buf := make([]byte, msgLen)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, fmt.Errorf("reading message body (%d bytes): %w", msgLen, err)
	}
	return buf, nil
}

// writeMessage writes one length-prefixed JSON message to stdout.
func writeMessage(w io.Writer, data []byte) error {
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(data)))
	if _, err := w.Write(lenBuf[:]); err != nil {
		return fmt.Errorf("writing length prefix: %w", err)
	}
	if _, err := w.Write(data); err != nil {
		return fmt.Errorf("writing message body: %w", err)
	}
	return nil
}

// sendResponse writes a Response back to Elixir via stdout.
func sendResponse(status, errMsg string) {
	resp := Response{Status: status, Error: errMsg}
	data, err := json.Marshal(resp)
	if err != nil {
		log.Printf("Failed to marshal response: %v", err)
		return
	}
	if err := writeMessage(os.Stdout, data); err != nil {
		log.Printf("Failed to send response: %v", err)
	}
}

// readLoop reads commands from stdin in a loop, calling handler for each one.
// Returns when stdin is closed (EOF) or an unrecoverable read error occurs.
func readLoop(handler func(cmd Command)) {
	for {
		data, err := readMessage(os.Stdin)
		if err != nil {
			if err == io.EOF {
				log.Println("Stdin closed (EOF)")
				return
			}
			// Check if it's an EOF wrapped in a ReadFull error
			if isEOF(err) {
				log.Println("Stdin closed")
				return
			}
			log.Printf("Read error: %v", err)
			return
		}

		var cmd Command
		if err := json.Unmarshal(data, &cmd); err != nil {
			log.Printf("JSON parse error: %v (raw: %q)", err, string(data))
			sendResponse("error", fmt.Sprintf("json parse error: %v", err))
			continue
		}

		if cmd.Cmd == "" {
			log.Printf("Received command with empty 'cmd' field")
			sendResponse("error", "missing cmd field")
			continue
		}

		handler(cmd)
	}
}

// isEOF checks whether an error wraps io.EOF or io.ErrUnexpectedEOF.
func isEOF(err error) bool {
	if err == nil {
		return false
	}
	if err == io.EOF || err == io.ErrUnexpectedEOF {
		return true
	}
	// Unwrap once for wrapped errors from ReadFull
	type unwrapper interface{ Unwrap() error }
	if u, ok := err.(unwrapper); ok {
		return isEOF(u.Unwrap())
	}
	return false
}
