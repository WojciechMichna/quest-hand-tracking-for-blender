import socket
import json
import os
import sys
import signal

# Configuration
UDP_IP = "0.0.0.0"
UDP_PORT = 5005
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_FOLDER = os.path.join(SCRIPT_DIR, "frames")

running = True


def signal_handler(_sig, _frame):
    global running
    print("\n[*] Stopping recorder (Ctrl+C)...")
    running = False
    sys.exit(0)


def main():
    global running
    signal.signal(signal.SIGINT, signal_handler)
    if hasattr(signal, "SIGBREAK"):
        signal.signal(signal.SIGBREAK, signal_handler)

    os.makedirs(OUTPUT_FOLDER, exist_ok=True)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((UDP_IP, UDP_PORT))
    # Timeout allows Windows Python to process Ctrl+C signals immediately
    sock.settimeout(0.3)

    print("=" * 60)
    print(f"[*] Quest UDP Packet Recorder started.")
    print(f"[*] Listening on port: {UDP_PORT}")
    print(f"[*] Saving packets to: {OUTPUT_FOLDER}/[n].txt")
    print(f"[*] Press Ctrl+C to stop.")
    print("=" * 60 + "\n")

    packet_num = 0

    try:
        while running:
            try:
                data, addr = sock.recvfrom(65535)
            except socket.timeout:
                continue

            filename = f"[{packet_num}].txt"
            filepath = os.path.join(OUTPUT_FOLDER, filename)

            # Format nicely as JSON
            try:
                parsed_json = json.loads(data.decode("utf-8"))
                content_to_save = json.dumps(parsed_json, indent=2)
            except Exception:
                content_to_save = data.decode("utf-8", errors="replace")

            with open(filepath, "w", encoding="utf-8") as f:
                f.write(content_to_save)

            print(f"[#{packet_num}] Saved: {filename} ({len(data)} B from {addr[0]})")
            packet_num += 1

    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        sock.close()
        print(f"[*] Recorder closed cleanly. Total packets saved: {packet_num}")


if __name__ == "__main__":
    main()
