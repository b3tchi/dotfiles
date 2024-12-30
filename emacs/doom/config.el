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
(setq doom-theme 'doom-one)
(if (eq system-type 'windows-nt)
	(setq doom-font (font-spec :family "Iosevka NFM Medium" :size 16)) ;windows
	(setq doom-font (font-spec :family "Iosevka Nerd Font Mono" :size 16)) ;linux
  )

;; This determines the style of line numbers in effect. If set to `nil', line
;; numbers are disabled. For relative line numbers, set this to `relative'.
(setq display-line-numbers-type t)

;; set indetation mod
(setq-default indent-tabs-mode nil)
(setq-default tab-width 4)
(setq indent-line-function 'insert-tab)

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

;;TMUX SUPPORT - adding ob-tmux
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

;;SQL SUPPORT - sqls
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

;;MERMAID SUPPORT - adding support for mermaid in org-mode
;;install package mermaid-ts-mode, ob-mermaid
(setq ob-mermaid-cli-path "/usr/bin/mmdc")

(org-babel-do-load-languages 'org-babel-load-languages
                             (append org-babel-load-languages '((mermaid     . t))))

;; Add mermaid language to `org-src-lang-modes`
(require 'mermaid-ts-mode)
(add-to-list 'auto-mode-alist '("\\.mermaid\\'" . mermaid-ts-mode))
(add-to-list 'org-src-lang-modes '("mermaid" . mermaid-ts))

;;PLANT UML SUPPORT
(setq plantuml-default-exec-mode 'executable)
(setq plantuml-executable-path "/usr/bin/plantuml")

(setq org-plantuml-exec-mode 'plantuml)
(setq org-plantuml-executable-path "/usr/bin/plantuml")

(org-babel-do-load-languages 'org-babel-load-languages
                             (append org-babel-load-languages '((plantuml . t))))

;; Enable plantuml-mode for PlantUML files
(require 'plantuml-mode)
(add-to-list 'auto-mode-alist '("\\.plantuml\\'" . plantuml-mode))

(add-to-list
 'org-src-lang-modes '("plantuml" . plantuml))

;;NUSHELL SUPPORT
;;install package nushell-ts-mode
(require 'nushell-ts-mode)
(org-babel-do-load-languages 'org-babel-load-languages
                             (append org-babel-load-languages '((nushell     . t))))

;; Add nushell language to `org-src-lang-modes`
(add-to-list 'auto-mode-alist '("\\.nu\\'" . nushell-ts-mode))
(add-to-list 'org-src-lang-modes '("nu" . nushell-ts))

;;enable lsp mode for nushell
(use-package lsp-mode
  :hook
  (nushell-ts-mode . lsp))

;; ob-nushell.el --- org-babel functions for Nushell shell
;; ob-elvish author: Diego Zamboni <diego@zzamboni.org>
;;; Code:
;;; Code:
(require 'ob)
(require 'ob-ref)
(require 'ob-comint)
(require 'ob-eval)
;; possibly require modes required for your language

;; set the language mode to be used for Nushell blocks
(add-to-list 'org-src-lang-modes '("nushell" . nushell))

;; optionally define a file extension for this language
(add-to-list 'org-babel-tangle-lang-exts '("nushell" . "nu"))

;; optionally declare default header arguments for this language
(defvar org-babel-default-header-args:nu '())

(defcustom org-babel-nushell-command "nu"
  "Command to use for executing Nushell code."
  :group 'org-babel
  :type 'string)

(defcustom ob-nushell-command-options ""
  "Option string that should be passed to nushell."
  :group 'org-babel
  :type 'string)

;; Format a variable passed with :var for assignment to an Nushell variable.
(defun ob-nushell-var-to-nushell (var)
  "Convert an elisp VAR into a string of Nushell source code."
  (format "'%S'" var))

;; This function expands the body of a source code block by prepending
;; module load statements and argument definitions to the body.
(defun org-babel-expand-body:nu (body params &optional processed-params)
  "Expand BODY according to PARAMS, return the expanded body.
Optional argument PROCESSED-PARAMS may contain PARAMS preprocessed by ‘org-babel-process-params’."
  (let* ((pparams (or processed-params (org-babel-process-params params)))
         (vars (org-babel--get-vars pparams))
         (use (assq :use pparams))
         (uses (if use (split-string (cdr use) ", *") '())))
    (when (assq :debug params)
      (message "pparams=%s" pparams)
      (message "vars=%s" vars)
      (message "uses=%s" uses))
    (concat
     (mapconcat ;; use modules
      (apply-partially 'concat "use ") uses "\n")
     "\n"
     (mapconcat ;; define any variables
      (lambda (pair)
        (format "let %s = %s"
                (car pair) (ob-nushell-var-to-nushell (cdr pair))))
      vars "\n") "\n" body "\n" )))

;; This is the main function which is called to evaluate a code
;; block.
;;
;; This function will evaluate the body of the source code and return
;; its output. For Nushell the :results header argument has no effect,
;; the full output of the executed code is always returned.
;;
;; In addition to the standard header arguments, you can specify :use
;; to indicate modules which should be loaded with the `use' statement
;; before executing the code. You can specify multiple modules
;; separated by commas.
(defun org-babel-execute:nu (body params)
  "Execute a BODY of Nushell code with org-babel with the given PARAMS.
This function is called by `org-babel-execute-src-block'"
  (message "executing Nushell source code block")
  (let* ((processed-params (org-babel-process-params params))
         ;; variables assigned for use in the block
         (vars (assoc :vars processed-params))
         ;; expand the body with `org-babel-expand-body:nu'
         (full-body (org-babel-expand-body:nu
                     body params processed-params)))
    (when (assq :debug params)
      (message "full-body=%s" full-body))
    (let* ((temporary-file-directory ".")
           (log (cdr (assoc :log params)))
           (tempfile (make-temp-file "nushell-")))
      (with-temp-file tempfile
        (insert full-body))
      (unwind-protect
          (shell-command-to-string
           (concat
            org-babel-nushell-command
            " "
            (when log (concat "--log " log ))
            " "
            ob-nushell-command-options
            " "
            (shell-quote-argument tempfile)))
        (delete-file tempfile)))
    ))

(provide 'ob-nushell)
;; ob-nushell.el ends here

(require 'ob-nushell)

;; TBD filter-out variables from imenu
;; (defun my-remove-variables-from-imenu-index (index)
;;   "Remove 'Variables' category entries from imenu INDEX."
;;   (seq-filter
;;    (lambda (item)
;;      (let ((name (car item)))
;;        (not (and (stringp name) (string-equal name "Variables")))))
;;    index))

;; (defun my-customize-imenu ()
;;   "Customize imenu to exclude 'Variables' entries."
;;   ;; Set custom index function that includes post-processing
;;   (setq imenu-create-index-function
;;         (lambda ()
;;           (my-remove-variables-from-imenu-index (imenu-default-create-index-function)))))

;; HYDRA WINDOWS MANAGEMENT
;; Add to desired mode hooks, for example, for programming modes:
;; (add-hook 'nushell-ts-mode-hook 'my-customize-imenu)
(require 'hydra)
(defhydra hydra-window (:color red :hint nil)
  "
 Focus: _h__j__k__l_
  Move: _H__J__K__L_
 Split: _b_ellow _s_ide by
Delete: _o_thers _c_urrent
Resize: _<_/_>_width _+_/_-_height
  Misc: _m_ark _u_ndo _r_edo _q_uit
"
  ("h" windmove-left)
  ("j" windmove-down)
  ("k" windmove-up)
  ("l" windmove-right)

  ("H" +evil/window-move-left nil)
  ("J" +evil/window-move-down nil)
  ("K" +evil/window-move-up nil)
  ("L" +evil/window-move-right nil)

  ("s" split-window-right)
  ("b" split-window-below)

  ;; winner-mode must be enabled
  ("u" winner-undo)
  ("r" winner-redo) ;;Fixme, not working?

  ("<" evil-window-increase-width) ;;Fixme, not working?
  (">" evil-window-decrease-width) ;;Fixme, not working?
  ("+" evil-window-increase-height) ;;Fixme, not working?
  ("-" evil-window-decrease-height) ;;Fixme, not working?

  ("o" delete-other-windows :exit t)
  ("c" delete-window)

  ("a" ace-window :exit t)
  ("q" nil)

  ;; ("z" ace-maximize-window "ace-one" :color blue)
  ;; ("B" ido-switch-buffer "buf")

  ("m" headlong-bookmark-jump))

(map! :leader :desc "window hydra" "w" #'hydra-window/body)

;; (setq ispell-program-name (executable-find "hunspell"))
