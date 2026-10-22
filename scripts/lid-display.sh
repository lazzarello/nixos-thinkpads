case "$1" in
  *close) @systemctl@ --user --machine=lee@.host start lid-display@off.service ;;
  *open)  @systemctl@ --user --machine=lee@.host start lid-display@on.service ;;
esac
