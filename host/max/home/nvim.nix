{ pkgs, ... }: {
  programs.nixvim = {
    enable = true;

    colorschemes.tokyonight.enable = true;

    globals = {
      mapleader = " ";
      maplocalleader = " ";
    };

    clipboard = {
      providers.wl-copy.enable = true;
      register = "unnamedplus";
    };

    opts = {
      background = "dark";
      relativenumber = true;
      cursorline = true;
      number = true;

      signcolumn = "yes";

      updatetime = 250;

      list = true;
      listchars.__raw = "{ tab = '» ', trail = '·', nbsp = '␣' }";

    };

    highlight = {
      Normal = {
        bg = "NONE";
        ctermbg = "NONE";
      };
      NormalFloat = {
        bg = "NONE";
        ctermbg = "NONE";
      };
      SignColumn = {
        bg = "NONE";
        ctermbg = "NONE";
      };
      EndOfBuffer = {
        bg = "NONE";
        ctermbg = "NONE";
      };
    };

    extraConfigLua = ''
      require('stay-centered').setup({ enable = true })
      require('mini.ai').setup()
    '';

    keymaps = [
      {
        mode = "n";
        key = "<Esc>";
        action = "<cmd>nohlsearch<CR>";
      }
      {
        mode = "n";
        key = "<leader>a";
        action.__raw = "function() require'harpoon':list():add() end";
      }
      {
        mode = "n";
        key = "<C-e>";
        action.__raw =
          "function() require'harpoon'.ui:toggle_quick_menu(require'harpoon':list()) end";
      }
      {
        mode = "n";
        key = "<C-j>";
        action.__raw = "function() require'harpoon':list():select(1) end";
      }
      {
        mode = "n";
        key = "<C-k>";
        action.__raw = "function() require'harpoon':list():select(2) end";
      }
      {
        mode = "n";
        key = "<C-l>";
        action.__raw = "function() require'harpoon':list():select(3) end";
      }
      {
        mode = "n";
        key = "<C-;>";
        action.__raw = "function() require'harpoon':list():select(4) end";
      }

      {
        mode = "n";
        key = "<leader>b";
        action = "<cmd>Neotree<CR>";
      }
      {
        mode = "n";
        key = "<leader>l";
        action = "<cmd>Neotree reveal<CR>";
      }
    ];

    autoCmd = [
      {
        event = [ "BufWritePre" ];
        pattern = "*";
        command = "lua vim.lsp.buf.format()";
      }
    ];

    diagnostic.settings.virtual_text = true;

    userCommands.W.command = "w";

    plugins = {

      web-devicons.enable = true;
      sleuth.enable = true;
      lastplace.enable = true;

      gitsigns.enable = true;
      highlight-colors.enable = true;
      todo-comments.enable = true;
      # smear-cursor.enable = true;
      goyo.enable = true;

      treesitter = {
        enable = true;
        settings = {
          ensureInstalled =
            [ "typescript" "rust" "php" "blade" "python" "nix" ];

          highlight = { enable = true; };

          indent = { enable = true; };
        };
      };

      lsp = {
        enable = true;

        servers = {
          ts_ls.enable = true;
          rust_analyzer = {
            enable = true;
            installCargo = true;
            installRustc = true;
          };
          clangd.enable = true;
          tailwindcss.enable = true;
          phpactor.enable = true;
          pylsp.enable = true;
          pyright.enable = true;
          nixd.enable = true;
          biome.enable = true;
        };

        keymaps = {
          extra = [
            {
              mode = "n";
              key = "gd";
              action.__raw = "require('telescope.builtin').lsp_definitions";
              options = { desc = "LSP: [G]oto [D]efinition"; };
            }
            {
              mode = "n";
              key = "gr";
              action.__raw = "require('telescope.builtin').lsp_references";
              options = { desc = "LSP: [G]oto [R]eferences"; };
            }
          ];

          lspBuf = {
            "<leader>." = {
              mode = [ "n" "x" ];
              action = "code_action";
              desc = "Code action";
            };
          };
        };
      };

      lazydev.enable = true;
      luasnip.enable = true;

      telescope = {
        enable = true;

        extensions = {
          fzf-native.enable = true;
          ui-select.enable = true;
        };

        keymaps = {
          "<leader>sf" = {
            mode = "n";
            action = "find_files";
            options = { desc = "[S]earch [F]iles"; };
          };
          "<leader>sk" = {
            mode = "n";
            action = "live_grep";
            options = { desc = "[S]earch [S]tring"; };
          };
        };
        settings = {
          extensions.__raw =
            "{ ['ui-select'] = { require('telescope.themes').get_dropdown() } }";
        };
      };

      cmp = {
        enable = true;
        settings = {
          snippet = {
            expand = ''
              function(args)
                require('luasnip').lsp_expand(args.body)
              end
            '';
          };

          completion = { completeopt = "menu,menuone,noinsert"; };
          formatting = {
            format = ''require("nvim-highlight-colors").format'';
          };
          mapping = {
            "<CR>" = "cmp.mapping.confirm { select = true }";
            "<Tab>" = "cmp.mapping.select_next_item()";
            "<S-Tab>" = "cmp.mapping.select_prev_item()";
            "<Down>" = "cmp.mapping.select_next_item()";
            "<Up>" = "cmp.mapping.select_prev_item()";
            "<C-j>" = "cmp.mapping.select_next_item()";
            "<C-k>" = "cmp.mapping.select_prev_item()";
          };
          sources = [
            {
              name = "lazydev";

              group_index = 0;
            }
            { name = "nvim_lsp"; }
            { name = "luasnip"; }
            { name = "path"; }
            { name = "nvim_lsp_signature_help"; }
          ];
        };
      };

      harpoon = {
        enable = true;
        settings.settings = { save_on_toggle = true; };
      };
      neo-tree = {
        enable = true;
        settings = {
          filesystem = {
            filtered_items = {
              visible = true;
            };
          };
        };
      };
      wakatime.enable = true;
      autoclose.enable = true;
      ts-autotag.enable = true;
      bullets.enable = true;
      spider = {
        enable = true;
        settings = {
          subwordMovement = true;
          skipInsignificantPunctuation = false;
        };
        keymaps = {
          motions = {
            "w" = "w";
            "e" = "e";
            "b" = "b";
          };
        };
      };

    };

    extraPlugins = with pkgs.vimPlugins; [ stay-centered-nvim mini-ai ];

  };
}
