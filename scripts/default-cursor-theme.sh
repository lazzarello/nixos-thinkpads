mkdir -p $out/share/icons/default
printf '[Icon Theme]\nName=default\nComment=Default cursor theme\nInherits=Adwaita\n' \
  > $out/share/icons/default/index.theme
