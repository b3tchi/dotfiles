;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

;; Place your private configuration here! Remember, you do not need to run 'doom
;; sync' after modifying this file!


;; Some functionality uses this to identify you, e.g. GPG configuration, email
;; clients, file templates and snippets. It is optional.
;; (setq user-full-name "John Doe"
;;       user-mail-address "john@doe.com")

;; Doom exposes five (optional) variables for controlling fonts in Doom:
;;
;; - `doom-font' -- the primary font to use
;; - `doom-variable-pitch-font' -- a non-monospace font (where applicable)
;; - `doom-big-font' -- used for `doom-big-font-mode'; use this for
;;   presentations or streaming.
;; - `doom-symbol-font' -- for symbols
;; - `doom-serif-font' -- for the `fixed-pitch-serif' face
;;
;; See 'C-h v doom-font' for documentation and more examples of what they
;; accept. For example:
;;
;;(setq doom-font (font-spec :family "Fira Code" :size 12 :weight 'semi-light)
;;      doom-variable-pitch-font (font-spec :family "Fira Sans" :size 13))
;;
;; If you or Emacs can't find your font, use 'M-x describe-font' to look them
;; up, `M-x eval-region' to execute elisp code, and 'M-x doom/reload-font' to
;; refresh your font settings. If Emacs still can't find your font, it likely
;; wasn't installed correctly. Font issues are rarely Doom issues!

;; There are two ways to load a theme. Both assume the theme is installed and
;; available. You can either set `doom-theme' or manually load a theme with the
;; `load-theme' function. This is the default:
(setq doom-theme 'doom-one
      doom-font (font-spec :family "Iosevka Nerd Font Mono" :size 16)
      )

;; This determines the style of line numbers in effect. If set to `nil', line
;; numbers are disabled. For relative line numbers, set this to `relative'.
(setq display-line-numbers-type t)

;; If you use `org' and don't want your org files in the default location below,
;; change `org-directory'. It must be set before org loads!
(setq org-directory "~/org/")

(use-package! org-super-agenda
  :init
  (setq org-super-agenda-groups '((:name "Today"
                                        :time-grid t
                                        :scheduled today)))
  :config
  (org-super-agenda-mode))


(setq org-journal-date-prefix "#+TITLE: "
      org-journal-time-prefix "* "
      org-journal-date-format "%Y-%m-%d %A"
      org-journal-file-format "%Y_%m_%d.org")

;; org-roam v1 & v2
(use-package org-roam
  :ensure t
  :init
  (setq org-roam-v2-ack t)
  :custom
  (org-roam-directory "~/org-roam")
  (org-roam-completion-everywhere t)
  :bind (("C-c n l" . org-roam-buffer-toggle)
         ("C-c n f" . org-roam-node-find)
         ("C-c n i" . org-roam-node-insert)
         :map org-mode-map
         ("C-M-i" . completion-at-point)
         :map org-roam-dailies-map
         ("Y" . org-roam-dailies-capture-yesterday)
         ("T" . org-roam-dailies-capture-tomorrow))
  :bind-keymap
  ("C-c n d" . org-roam-dailies-map)
  :config
  (require 'org-roam-dailies) ;; Ensure the keymap is available
  (org-roam-db-autosync-mode))

;; relative to org-roam-directory must exists
(setq org-roam-dailies-directory "journals/")

;; download images from remote source
(setq org-display-remote-inline-images 'download)

;; auto commit messages
(use-package! git-auto-commit-mode
    :ensure t)

(defun my-commit-settings ()
  (setq gac-automatically-add-new-files-p t)
  (setq gac-automatically-push-p t)
  )

;; (add-hook 'org-mode-hook 'my-commit-settings)
(add-hook 'org-mode-hook
  (lambda () (when (s-prefix? (expand-file-name "~/org-roam/")
                      (buffer-file-name (current-buffer)))
                (my-commit-settings))))
;; ;; Plan B for images
;; ;; we look to doom emacs for an example how to get remote images also working
;; ;; for normal http / https links
;; ;; 1. image data handler
;; (defun org-http-image-data-fn (protocol link _description)
;;   "Interpret LINK as an URL to an image file."
;;   (when (and (image-type-from-file-name link)
;;              (not (eq org-display-remote-inline-images 'skip)))
;;     (if-let (buf (url-retrieve-synchronously (concat protocol ":" link)))
;;         (with-current-buffer buf
;;           (goto-char (point-min))
;;           (re-search-forward "\r?\n\r?\n" nil t)
;;           (buffer-substring-no-properties (point) (point-max)))
;;       (message "Download of image \"%s\" failed" link)
;;       nil)))

;; ;; 2. add this as link parameter for http and https
;; (org-link-set-parameters "http"  :image-data-fun #'org-http-image-data-fn)
;; (org-link-set-parameters "https" :image-data-fun #'org-http-image-data-fn)

;; ;; moved to packages.el
;; 3. pull in org-yt which will advise ~org-display-inline-images~ how to do the extra handling
;; (use-package org-yt
;;   :quelpa (org-yt :fetcher github :repo "TobiasZawada/org-yt"))
;; (require 'org-yt)


;; Whenever you reconfigure a package, make sure to wrap your config in an
;; `after!' block, otherwise Doom's defaults may override your settings. E.g.
;;
;;   (after! PACKAGE
;;     (setq x y))
;;
;; The exceptions to this rule:
;;
;;   - Setting file/directory variables (like `org-directory')
;;   - Setting variables which explicitly tell you to set them before their
;;     package is loaded (see 'C-h v VARIABLE' to look up their documentation).
;;   - Setting doom variables (which start with 'doom-' or '+').
;;
;; Here are some additional functions/macros that will help you configure Doom.
;;
;; - `load!' for loading external *.el files relative to this one
;; - `use-package!' for configuring packages
;; - `after!' for running code after a package has loaded
;; - `add-load-path!' for adding directories to the `load-path', relative to
;;   this file. Emacs searches the `load-path' when you load packages with
;;   `require' or `use-package'.
;; - `map!' for binding new keys
;;
;; To get information about any of these functions/macros, move the cursor over
;; the highlighted symbol at press 'K' (non-evil users must press 'C-c c k').
;; This will open documentation for it, including demos of how they are used.
;; Alternatively, use `C-h o' to look up a symbol (functions, variables, faces,
;; etc).
;;
;; You can also try 'gd' (or 'C-c c d') to jump to their definition and see how
;; they are implemented.

;; debuging of python
(use-package! dap-mode)

;; (require 'dap-python)
(after! dap-mode
  (setq dap-python-debugger 'debugpy))

(map! :map dap-mode-map
      :leader
      ;; :prefix ("d" . "dap")
      :prefix "d"
      ;; basics
      :desc "dap next"          "n" #'dap-next
      :desc "dap step in"       "i" #'dap-step-in
      :desc "dap step out"      "o" #'dap-step-out
      :desc "dap continue"      "c" #'dap-continue
      :desc "dap hydra"         "h" #'dap-hydra
      :desc "dap debug restart" "r" #'dap-debug-restart
      :desc "dap debug"         "s" #'dap-debug

      ;; debug
      ;; :prefix ("dd" . "Debug")
      :prefix "dd"
      :desc "dap debug recent"  "r" #'dap-debug-recent
      :desc "dap debug last"    "l" #'dap-debug-last

      ;; eval
      ;; :prefix ("de" . "Eval")
      :prefix "de"
      :desc "eval"                "e" #'dap-eval
      :desc "eval region"         "r" #'dap-eval-region
      :desc "eval thing at point" "s" #'dap-eval-thing-at-point
      :desc "add expression"      "a" #'dap-ui-expressions-add
      :desc "remove expression"   "d" #'dap-ui-expressions-remove

      ;; :prefix ("db" . "Breakpoint")
      :prefix "db"
      :desc "dap breakpoint toggle"      "b" #'dap-breakpoint-toggle
      :desc "dap breakpoint condition"   "c" #'dap-breakpoint-condition
      :desc "dap breakpoint hit count"   "h" #'dap-breakpoint-hit-condition
      :desc "dap breakpoint log message" "l" #'dap-breakpoint-log-message
      )

;; adding ob-tmux
(use-package ob-tmux
  ;; Install package automatically (optional)
  :ensure t
  :custom
  (org-babel-default-header-args:tmux
   '((:results . "silent")	;
     (:session . "default")	; The default tmux session to send code to
     (:socket  . nil)))		; The default tmux socket to communicate with
  ;; The tmux sessions are prefixed with the following string.
  ;; You can customize this if you like.
  (org-babel-tmux-session-prefix "ob-")
  ;; The terminal that will be used.
  ;; You can also customize the options passed to the terminal.
  ;; The default terminal is "gnome-terminal" with options "--".
  ;; ORIGINAL
  ;; (org-babel-tmux-terminal "xterm")
  ;; (org-babel-tmux-terminal-opts '("-T" "ob-tmux" "-e"))
  ;; CHANGED
  (org-babel-tmux-terminal "~/.local/bin/org-tmux.sh")
  (org-babel-tmux-terminal-opts nil)
  ;
  ;; Finally, if your tmux is not in your $PATH for whatever reason, you
  ;; may set the path to the tmux binary as follows:
  (org-babel-tmux-location "/usr/bin/tmux"))

;;lsp sqls
(add-hook 'sql-mode-hook 'lsp)
(setq lsp-sqls-workspace-config-path nil)
(setq lsp-sqls-connections
      '(
        ((driver . "mssql") (dataSourceName . "sqlserver://sa:4dm1n1-str4t0r@localhost:1433?database=hr_db&encrypt=true&trustServerCertificate=true"))
        ))

;;enable lsp in zoomed [C-c '](tangled) sql source block
(defun org-babel-edit-prep:sql (babel-info)
  (setq-local buffer-file-name (->> babel-info caddr (alist-get :tangle)))
  (lsp))
