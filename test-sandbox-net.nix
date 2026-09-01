{ pkgs ? import <nixpkgs> {} }:

# Test whether a Nix build sandbox can reach localhost ports.
# Run:  nix-build test-sandbox-net.nix
# First, in another terminal:  nc -l 12345
# (or python3 -m http.server 12345)

pkgs.runCommand "test-sandbox-net" {
  nativeBuildInputs = [ pkgs.socat ];
} ''
  echo "=== Sandbox network test ==="
  echo "Trying to connect to host localhost:12345..."

  # Try a raw TCP connect to localhost
  if socat -T2 - TCP:127.0.0.1:12345 </dev/null 2>&1; then
    echo "SUCCESS: sandbox can reach localhost:12345"
  else
    echo "BLOCKED: sandbox cannot reach localhost:12345 (exit $?)"
  fi

  # Also try the loopback via different addresses
  for addr in 127.0.0.1 0.0.0.0 ::1; do
    echo -n "  $addr:12345 -> "
    if socat -T2 /dev/null "TCP:[$addr]:12345" 2>/dev/null; then
      echo "open"
    else
      echo "blocked/refused"
    fi
  done

  # Check what the sandbox looks like
  echo ""
  echo "=== Network interfaces ==="
  ifconfig 2>/dev/null || ip addr 2>/dev/null || echo "(no network tools)"

  echo ""
  echo "=== /etc/resolv.conf ==="
  cat /etc/resolv.conf 2>/dev/null || echo "(not present)"

  mkdir -p $out
  echo "done" > $out/result
''
