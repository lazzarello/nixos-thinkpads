{ pkgs, ... }:

{
  # Neovim and the toolchain LazyVim expects.
  #
  # Division of responsibility, which is the thing that was previously hard to
  # untangle:
  #
  #   Nix (this file)     the neovim binary, language servers, formatters,
  #                       linters, and the external tools plugins shell out to
  #   lazy.nvim           plugin Lua, pinned by ~/.config/nvim/lazy-lock.json
  #   ~/.config/nvim      your own config, tracked in its own git repo
  #
  # Mason is disabled in lua/plugins/nix.lua because it ships dynamically
  # linked binaries that cannot run on NixOS. So: to add a language server,
  # add it here and rebuild -- not with :Mason.

  environment.systemPackages = with pkgs; [
    neovim

    # --- tools LazyVim core expects on PATH ---
    git
    lazygit # lazyvim.plugins.extras.lang.git
    ripgrep # grep picker
    fd # file picker
    gcc # treesitter compiles parsers with a C compiler
    gnumake
    unzip
    wget
    curl

    # --- Lua (config editing, lua_ls is wired up via .neoconf.json) ---
    lua-language-server
    stylua

    # --- Nix, since the config lives here now ---
    nixd
    nixfmt-rfc-style

    # --- lang.python ---
    (python3.withPackages (ps: with ps; [ ]))
    pyright
    ruff

    # --- lang.rust ---
    rust-analyzer
    rustfmt
    clippy

    # --- lang.typescript.tsgo / lang.json / lang.yaml ---
    nodejs
    typescript
    typescript-language-server
    vscode-langservers-extracted # json, html, css, eslint
    yaml-language-server

    # --- lang.docker ---
    dockerfile-language-server-nodejs
    docker-compose-language-service
    hadolint

    # --- lang.sql ---
    sqlfluff

    # --- lang.markdown ---
    marksman
    markdownlint-cli2
  ];

  # Make nvim the default editor for git, systemctl edit, sudoedit, etc.
  environment.variables.EDITOR = "nvim";
}
