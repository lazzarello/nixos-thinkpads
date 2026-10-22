# Toggle screen recording with wl-screenrec.
#
# Recording needs start *and* stop, unlike niri's screenshot action which is
# one-shot. So this is a toggle: the first press starts, the second stops by
# sending SIGINT, which lets wl-screenrec finalise the container. Killing it
# harder (SIGKILL) leaves an unplayable file.
#
# Usage:
#   screenrec.sh screen [output]   whole output
#   screenrec.sh region            select a region with slurp
#   screenrec.sh stop              stop without toggling
#
# Audio: pass a device in SCREENREC_AUDIO_DEVICE to record sound. Use a sink's
# .monitor to capture desktop audio, or an input for the mic. List them with
#   pactl list short sources
set -uo pipefail

DIR="${SCREENREC_DIR:-$HOME/Videos/Recordings}"
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/wl-screenrec.pid"

notify() {
  # DMS owns notifications here; notify-send is not installed. A --file gives
  # the notification Open and Open Folder actions.
  command -v dms >/dev/null || return 0
  if [ -n "${3:-}" ]; then
    dms notify "$1" "${2:-}" --icon videocam --file "$3" --app "Screen recording" 2>/dev/null || true
  else
    dms notify "$1" "${2:-}" --icon videocam --app "Screen recording" 2>/dev/null || true
  fi
}

running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

stop() {
  if running; then
    local pid
    pid=$(cat "$PIDFILE")
    # SIGINT, so the muxer writes the trailer and the file is playable.
    kill -INT "$pid" 2>/dev/null
    # Wait for it to finish writing rather than reporting success immediately.
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    rm -f "$PIDFILE"
    # Newest recording, for the notification's Open action. Uses find -printf
    # with an epoch prefix rather than parsing ls output, so filenames with
    # spaces or newlines cannot break it.
    local last
    last=$(find "$DIR" -maxdepth 1 -type f -name '*.mp4' -printf '%T@\t%p\n' 2>/dev/null |
      sort -rn | head -1 | cut -f2-)
    notify "Recording stopped" "$(basename "${last:-}")" "${last:-}"
  else
    rm -f "$PIDFILE"
  fi
}

if [ "${1:-}" = "stop" ]; then
  stop
  exit 0
fi

# Second press of the same key: stop.
if running; then
  stop
  exit 0
fi

mkdir -p "$DIR"
FILE="$DIR/$(date +%Y-%m-%d_%H-%M-%S).mp4"

args=()
case "${1:-screen}" in
region)
  geom=$(slurp 2>/dev/null) || exit 0 # cancelled with Escape
  [ -z "$geom" ] && exit 0
  args+=(-g "$geom")
  ;;
screen)
  [ -n "${2:-}" ] && args+=(-o "$2")
  ;;
*)
  echo "usage: $0 [screen|region|stop]" >&2
  exit 1
  ;;
esac

if [ -n "${SCREENREC_AUDIO_DEVICE:-}" ]; then
  args+=(--audio --audio-device "$SCREENREC_AUDIO_DEVICE")
fi

wl-screenrec "${args[@]}" -f "$FILE" &
echo $! >"$PIDFILE"

notify "Recording started" "$(basename "$FILE")"
