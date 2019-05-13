;;; livescript-mode.el --- Major mode to edit LiveScript files in Emacs

;; Copyright (C) 2010 Chris Wanstrath

;; Version: 0.4.1
;; Keywords: LiveScript major mode
;; Author: Chris Wanstrath <chris@ozmm.org>
;; URL: http://github.com/defunkt/livescript-mode

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

;;; Commentary

;; Provides syntax highlighting, indentation support, imenu support,
;; a menu bar, and a few cute commands.

;; ## Indentation

;; ### TAB Theory

;; It goes like this: when you press `TAB`, we indent the line unless
;; doing so would make the current line more than two indentation levels
;; deepers than the previous line. If that's the case, remove all
;; indentation.

;; Consider this code, with point at the position indicated by the
;; caret:

;;     line1()
;;       line2()
;;       line3()
;;          ^

;; Pressing `TAB` will produce the following code:

;;     line1()
;;       line2()
;;         line3()
;;            ^

;; Pressing `TAB` again will produce this code:

;;     line1()
;;       line2()
;;     line3()
;;        ^

;; And so on. I think this is a pretty good way of getting decent
;; indentation with a whitespace-sensitive language.

;; ### Newline and Indent

;; We all love hitting `RET` and having the next line indented
;; properly. Given this code and cursor position:

;;     line1()
;;       line2()
;;       line3()
;;             ^

;; Pressing `RET` would insert a newline and place our cursor at the
;; following position:

;;     line1()
;;       line2()
;;       line3()

;;       ^

;; In other words, the level of indentation is maintained. This
;; applies to comments as well. Combined with the `TAB` you should be
;; able to get things where you want them pretty easily.

;; ### Indenters

;; `class`, `for`, `if`, and possibly other keywords cause the next line
;; to be indented a level deeper automatically.

;; For example, given this code and cursor position::

;;     class Animal
;;                 ^

;; Pressing enter would produce the following:

;;     class Animal

;;       ^

;; That is, indented a column deeper.

;; This also applies to lines ending in `->`, `=>`, `{`, `[`, and
;; possibly more characters.

;; So this code and cursor position:

;;     $('#demo').click ->
;;                        ^

;; On enter would produce this:

;;     $('#demo').click ->

;;       ^

;; Pretty slick.

;; Thanks to Jeremy Ashkenas for CoffeeScript, and to
;; http://xahlee.org/emacs/elisp_syntax_coloring.html, Jason
;; Blevins's markdown-mode.el and Steve Yegge's js2-mode for guidance.

;; TODO:
;; - Make prototype accessor assignments like `String::length: -> 10` pretty.
;; - mirror-mode - close brackets and parens automatically

;;; Code:

(require 'comint)
(require 'easymenu)
(require 'font-lock)

(eval-when-compile
  (require 'cl))

;;
;; Customizable Variables
;;

(defconst livescript-mode-version "0.4.2"
  "The version of `livescript-mode'.")

(defgroup livescript nil
  "A LiveScript major mode."
  :group 'languages)

(defcustom livescript-tab-width 2
  "The tab width to use when indenting."
  :type 'integer
  :group 'livescript)

(defcustom livescript-command "lsc"
  "The LiveScript command used for evaluating code."
  :type 'string
  :group 'livescript)

(defcustom livescript-js-directory ""
  "The directory for compiled JavaScript files output"
  :type 'string
  :group 'livescript)

(defcustom js2livescript-command "js2livescript"
  "The js2livescript command used for evaluating code."
  :type 'string
  :group 'livescript)

(defcustom livescript-args-repl '("")
  "The arguments to pass to `livescript-command' to start a REPL."
  :type 'list
  :group 'livescript)

(defcustom livescript-args-compile '("-c")
  "The arguments to pass to `livescript-command' to compile a file."
  :type 'list
  :group 'livescript)

(defcustom livescript-compiled-buffer-name "*livescript-compiled*"
  "The name of the scratch buffer used for compiled LiveScript."
  :type 'string
  :group 'livescript)

(defcustom livescript-compile-jump-to-error t
  "Whether to jump to the first error if compilation fails.
Since the livescript compiler does not always include a line number in
its error messages, this is not always possible."
  :type 'boolean
  :group 'livescript)

(defcustom livescript-watch-buffer-name "*livescript-watch*"
  "The name of the scratch buffer used when using the --watch flag
with LiveScript."
  :type 'string
  :group 'livescript)

(defcustom livescript-mode-hook nil
  "Hook called by `livescript-mode'.  Examples:

      ;; LiveScript uses two spaces.
      (make-local-variable 'tab-width)
      (set 'tab-width 2)

      ;; If you don't want your compiled files to be wrapped
      (setq livescript-args-compile '(\"-c\" \"--bare\"))

      ;; Emacs key binding
      (define-key livescript-mode-map [(meta r)] 'livescript-compile-buffer)

      ;; Bleeding edge.
      (setq livescript-command \"~/dev/livescript\")

      ;; Compile '.livescript' files on every save
      (and (file-exists-p (buffer-file-name))
           (file-exists-p (livescript-compiled-file-name))
           (livescript-cos-mode t)))"
  :type 'hook
  :group 'livescript)

(defvar working-on-file nil)

(defvar livescript-mode-map
  (let ((map (make-sparse-keymap)))
    ;; key bindings
    (define-key map (kbd "A-r") 'livescript-compile-buffer)
    (define-key map (kbd "A-R") 'livescript-compile-region)
    (define-key map (kbd "A-M-r") 'livescript-repl)
    (define-key map [remap comment-dwim] 'livescript-comment-dwim)
    (define-key map [remap newline-and-indent] 'livescript-newline-and-indent)
    (define-key map "\C-m" 'livescript-newline-and-indent)
    (define-key map "\C-c\C-o\C-s" 'livescript-cos-mode)
    (define-key map "\177" 'livescript-dedent-line-backspace)
    (define-key map (kbd "C-c C-<") 'livescript-indent-shift-left)
    (define-key map (kbd "C-c C->") 'livescript-indent-shift-right)
    map)
  "Keymap for LiveScript major mode.")

;;
;; Commands
;;

(defun livescript-repl ()
  "Launch a LiveScript REPL using `livescript-command' as an inferior mode."
  (interactive)

  (unless (comint-check-proc "*LiveScriptREPL*")
    (set-buffer
     (apply 'make-comint "LiveScriptREPL"
            "env"
            nil (append (list "NODE_NO_READLINE=1" livescript-command) livescript-args-repl))))

  (pop-to-buffer "*LiveScriptREPL*"))

(defun livescript-compiled-file-name (&optional filename)
  (setq working-on-file (expand-file-name (or filename (buffer-file-name))))
  (unless (string= livescript-js-directory "")
      (setq working-on-file (expand-file-name (concat (file-name-directory working-on-file) livescript-js-directory (file-name-nondirectory working-on-file)))))
  "Returns the name of the JavaScript file compiled from a LiveScript file.
If FILENAME is omitted, the current buffer's file name is used."
  (concat (file-name-sans-extension working-on-file) ".js"))

(defun livescript-compile-file ()
  "Compiles and saves the current file to disk in a file of the same
base name, with extension `.js'.  Subsequent runs will overwrite the
file.

If there are compilation errors, point is moved to the first
(see `livescript-compile-jump-to-error')."
  (interactive)
  (let ((compiler-output (shell-command-to-string (livescript-command-compile (buffer-file-name)))))
    (if (string= compiler-output "")
        (message "Compiled and saved %s" (livescript-compiled-file-name))
      (let* ((msg (car (split-string compiler-output "[\n\r]+")))
             (line (and (string-match "on line \\([0-9]+\\)" msg)
                        (string-to-number (match-string 1 msg)))))
        (message msg)
        (when (and livescript-compile-jump-to-error line (> line 0))
          (goto-char (point-min))
          (forward-line (1- line)))))))

(defun livescript-compile-buffer ()
  "Compiles the current buffer and displays the JavaScript in a buffer
called `livescript-compiled-buffer-name'."
  (interactive)
  (save-excursion
    (livescript-compile-region (point-min) (point-max))))

(defun livescript-compile-region (start end)
  "Compiles a region and displays the JavaScript in a buffer called
`livescript-compiled-buffer-name'."
  (interactive "r")

  (let ((buffer (get-buffer livescript-compiled-buffer-name)))
    (when buffer
      (with-current-buffer buffer
        (erase-buffer))))

  (apply (apply-partially 'call-process-region start end livescript-command nil
                          (get-buffer-create livescript-compiled-buffer-name)
                          nil)
         (append livescript-args-compile (list "-s" "-p")))

  (let ((buffer (get-buffer livescript-compiled-buffer-name)))
    (display-buffer buffer)
    (with-current-buffer buffer
      (let ((buffer-file-name "tmp.js")) (set-auto-mode)))))

(defun livescript-js2livescript-replace-region (start end)
  "Convert JavaScript in the region into LiveScript."
  (interactive "r")

  (let ((buffer (get-buffer livescript-compiled-buffer-name)))
    (when buffer
      (kill-buffer buffer)))

  (call-process-region start end
                       js2livescript-command nil
                       (current-buffer))
  (delete-region start end))

(defun livescript-version ()
  "Show the `livescript-mode' version in the echo area."
  (interactive)
  (message (concat "livescript-mode version " livescript-mode-version)))

(defun livescript-watch (dir-or-file)
  "Run `livescript-run-cmd' with the --watch flag on a directory or file."
  (interactive "fDirectory or File: ")
  (let ((livescript-compiled-buffer-name livescript-watch-buffer-name)
        (args (mapconcat 'identity (append livescript-args-compile (list "--watch" (expand-file-name dir-or-file))) " ")))
    (livescript-run-cmd args)))

;;
;; Menubar
;;

(easy-menu-define livescript-mode-menu livescript-mode-map
  "Menu for LiveScript mode"
  '("LiveScript"
    ["Compile File" livescript-compile-file]
    ["Compile Buffer" livescript-compile-buffer]
    ["Compile Region" livescript-compile-region]
    ["REPL" livescript-repl]
    "---"
    ["Version" livescript-version]
    ))

;;
;; Define Language Syntax
;;

;; String literals
(defvar livescript-word-regexp "\\\\\\w+")
(defvar livescript-word-list-regexp "<\\[[^]]*\\]>")
(defvar livescript-string-regexp "\"\\([^\\]\\|\\\\.\\)*?\"\\|'\\([^\\]\\|\\\\.\\)*?'")

;; Instance variables (implicit this)
(defvar livescript-this-regexp "@\\(\\w\\|_\\)*\\|this")

;; Prototype::access
(defvar livescript-prototype-regexp "\\(\\(\\w\\|\\.\\|_\\| \\|$\\)+?\\)::\\(\\(\\w\\|\\.\\|_\\| \\|$\\)+?\\):")

;; Assignment
(defvar livescript-assign-regexp "\\(\\(\\w\\|\\.\\|_\\|$\\|-\\)+?\s*\\):")

;; Local Assignment
(defvar livescript-local-assign-regexp "\\(\\(_\\|\\w\\|\\$\\)+\\)\s+=")

;; Lambda
(defvar livescript-lambda-regexp "\\((.+)\\)?\\s *\\(->\\|=>\\)")

;; Namespaces
(defvar livescript-namespace-regexp "\\b\\(class\\s +\\(\\S +\\)\\)\\b")

;; Booleans
(defvar livescript-boolean-regexp "\\b\\(true\\|false\\|yes\\|no\\|on\\|off\\|null\\|undefined\\|void\\)\\b")

;; Regular Expressions
(defvar livescript-regexp-regexp "\\/\\(\\\\.\\|\\[\\(\\\\.\\|.\\)+?\\]\\|[^/
]\\)+?\\/")

;; JavaScript Keywords
(defvar livescript-js-keywords
      '("if" "else" "new" "return" "try" "catch"
        "finally" "throw" "break" "continue" "for" "in" "while"
        "delete" "instanceof" "typeof" "switch" "super" "extends"
        "class" "until" "loop" "require"))

;; Reserved keywords either by JS or CS.
(defvar livescript-js-reserved
      '("case" "default" "do" "function" "var" "void" "with"
        "const" "let" "debugger" "enum" "export" "import" "native"
        "__extends" "__hasProp"))

;; LiveScript keywords.
(defvar livescript-cs-keywords
      '("then" "unless" "and" "or" "is" "own"
        "isnt" "not" "of" "by" "when" "typeof!" "require"))

;; Iced LiveScript keywords
(defvar iced-livescript-cs-keywords
  '("await" "defer"))

;; Regular expression combining the above three lists.
(defvar livescript-keywords-regexp
  ;; keywords can be member names.
  (concat "[^.]"
	  (regexp-opt (append livescript-js-reserved
			      livescript-js-keywords
			      livescript-cs-keywords
			      iced-livescript-cs-keywords) 'words)))

(defvar livescript-string-interpolation-regexp "#{[^}\n\\\\]*\\(?:\\\\.[^}\n\\\\]*\\)*}")

;; Create the list for font-lock. Each class of keyword is given a
;; particular face.
(defvar livescript-font-lock-keywords
  ;; *Note*: order below matters. `livescript-keywords-regexp' goes last
  ;; because otherwise the keyword "state" in the function
  ;; "state_entry" would be highlighted.
  `((,livescript-word-regexp . font-lock-string-face)
    (,livescript-word-list-regexp . font-lock-string-face)
    (,livescript-string-regexp . font-lock-string-face)
    (,livescript-this-regexp . font-lock-variable-name-face)
    (,livescript-prototype-regexp . font-lock-variable-name-face)
    (,livescript-assign-regexp . font-lock-type-face)
    (,livescript-local-assign-regexp 1 font-lock-variable-name-face)
    (,livescript-regexp-regexp . font-lock-constant-face)
    (,livescript-boolean-regexp . font-lock-constant-face)
    (,livescript-lambda-regexp . (2 font-lock-function-name-face))
    (,livescript-keywords-regexp 1 font-lock-keyword-face)
    (,livescript-string-interpolation-regexp 0 font-lock-constant-face t)))

;;
;; Helper Functions
;;

(defun livescript-comment-dwim (arg)
  "Comment or uncomment current line or region in a smart way.
For details, see `comment-dwim'."
  (interactive "*P")
  (require 'newcomment)
  (let ((deactivate-mark nil) (comment-start "#") (comment-end ""))
    (comment-dwim arg)))

(defun livescript-command-compile (file-name)
  "Run `livescript-command' to compile FILE."
  (let (
	(full-file-name
	 (expand-file-name file-name))
	(output-directory
	 (concat " -o " (file-name-directory (expand-file-name file-name)) livescript-js-directory)))
    (mapconcat 'identity (append (list livescript-command) livescript-args-compile (list output-directory) (list full-file-name)) " ")))

(defun livescript-run-cmd (args)
  "Run `livescript-command' with the given arguments, and display the
output in a compilation buffer."
  (interactive "sArguments: ")
  (let ((compilation-buffer-name-function (lambda (this-mode)
                                            (generate-new-buffer-name livescript-compiled-buffer-name))))
    (compile (concat livescript-command " " args))))

;;
;; imenu support
;;

;; This is a pretty naive but workable way of doing it. First we look
;; for any lines that starting with `livescript-assign-regexp' that include
;; `livescript-lambda-regexp' then add those tokens to the list.
;;
;; Should cover cases like these:
;;
;; minus: (x, y) -> x - y
;; String::length: -> 10
;; block: ->
;;   print('potion')
;;
;; Next we look for any line that starts with `class' or
;; `livescript-assign-regexp' followed by `{` and drop into a
;; namespace. This means we search one indentation level deeper for
;; more assignments and add them to the alist prefixed with the
;; namespace name.
;;
;; Should cover cases like these:
;;
;; class Person
;;   print: ->
;;     print 'My name is ' + this.name + '.'
;;
;; class Policeman extends Person
;;   constructor: (rank) ->
;;     @rank: rank
;;   print: ->
;;     print 'My name is ' + this.name + " and I'm a " + this.rank + '.'
;;
;; TODO:
;; app = {
;;   window:  {width: 200, height: 200}
;;   para:    -> 'Welcome.'
;;   button:  -> 'OK'
;; }

(defun livescript-imenu-create-index ()
  "Create an imenu index of all methods in the buffer."
  (interactive)

  ;; This function is called within a `save-excursion' so we're safe.
  (goto-char (point-min))

  (let ((index-alist '()) assign pos indent ns-name ns-indent)
    ;; Go through every assignment that includes -> or => on the same
    ;; line or starts with `class'.
    (while (re-search-forward
            (concat "^\\(\\s *\\)"
                    "\\("
                      livescript-assign-regexp
                      ".+?"
                      livescript-lambda-regexp
                    "\\|"
                      livescript-namespace-regexp
                    "\\)")
            (point-max)
            t)

      ;; If this is the start of a new namespace, save the namespace's
      ;; indentation level and name.
      (when (match-string 8)
        ;; Set the name.
        (setq ns-name (match-string 8))

        ;; If this is a class declaration, add :: to the namespace.
        (setq ns-name (concat ns-name "::"))

        ;; Save the indentation level.
        (setq ns-indent (length (match-string 1))))

      ;; If this is an assignment, save the token being
      ;; assigned. `Please.print:` will be `Please.print`, `block:`
      ;; will be `block`, etc.
      (when (setq assign (match-string 3))
          ;; The position of the match in the buffer.
          (setq pos (match-beginning 3))

          ;; The indent level of this match
          (setq indent (length (match-string 1)))

          ;; If we're within the context of a namespace, add that to the
          ;; front of the assign, e.g.
          ;; constructor: => Policeman::constructor
          (when (and ns-name (> indent ns-indent))
            (setq assign (concat ns-name assign)))

          ;; Clear the namespace if we're no longer indented deeper
          ;; than it.
          (when (and ns-name (<= indent ns-indent))
            (setq ns-name nil)
            (setq ns-indent nil))

          ;; Add this to the alist. Done.
          (push (cons assign pos) index-alist)))

    ;; Return the alist.
    index-alist))

;;
;; Indentation
;;

;;; The theory is explained in the README.

(defun livescript-indent-line ()
  "Indent current line as LiveScript."
  (interactive)

  (if (= (point) (point-at-bol))
      (insert-tab)
    (save-excursion
      (let ((prev-indent (livescript-previous-indent))
            (cur-indent (current-indentation)))
        ;; Shift one column to the left
        (beginning-of-line)
        (insert-tab)

        (when (= (point-at-bol) (point))
          (forward-char livescript-tab-width))

        ;; We're too far, remove all indentation.
        (when (> (- (current-indentation) prev-indent) livescript-tab-width)
          (backward-to-indentation 0)
          (delete-region (point-at-bol) (point)))))))

(defun livescript-previous-indent ()
  "Return the indentation level of the previous non-blank line."
  (save-excursion
    (forward-line -1)
    (if (bobp)
        0
      (progn
        (while (and (looking-at "^[ \t]*$") (not (bobp))) (forward-line -1))
        (current-indentation)))))

(defun livescript-newline-and-indent ()
  "Insert a newline and indent it to the same level as the previous line."
  (interactive)

  ;; Remember the current line indentation level,
  ;; insert a newline, and indent the newline to the same
  ;; level as the previous line.
  (let ((prev-indent (current-indentation)) (indent-next nil))
    (delete-horizontal-space t)
    (newline)
    (insert-tab (/ prev-indent livescript-tab-width))

    ;; We need to insert an additional tab because the last line was special.
    (when (livescript-line-wants-indent)
      (insert-tab)))

  ;; Last line was a comment so this one should probably be,
  ;; too. Makes it easy to write multi-line comments (like the one I'm
  ;; writing right now).
  (when (livescript-previous-line-is-comment)
    (insert "# ")))

(defun livescript-dedent-line-backspace (arg)
  "Unindent to increment of `livescript-tab-width' with ARG==1 when
called from first non-blank char of line.

Delete ARG spaces if ARG!=1."
  (interactive "*p")
  (if (and (= 1 arg)
           (= (point) (save-excursion
                        (back-to-indentation)
                        (point)))
           (not (bolp)))
      (let ((extra-space-count (% (current-column) livescript-tab-width)))
        (backward-delete-char-untabify
         (if (zerop extra-space-count)
             livescript-tab-width
           extra-space-count)))
    (backward-delete-char-untabify arg)))

;; Indenters help determine whether the current line should be
;; indented further based on the content of the previous line. If a
;; line starts with `class', for instance, you're probably going to
;; want to indent the next line.

(defvar livescript-indenters-bol '("class" "for" "if" "try" "while")
  "Keywords or syntax whose presence at the start of a line means the
next line should probably be indented.")

(defun livescript-indenters-bol-regexp ()
  "Builds a regexp out of `livescript-indenters-bol' words."
  (regexp-opt livescript-indenters-bol 'words))

(defvar livescript-indenters-eol '(?> ?{ ?\[)
  "Single characters at the end of a line that mean the next line
should probably be indented.")

(defun livescript-line-wants-indent ()
  "Return t if the current line should be indented relative to the
previous line."
  (interactive)

  (save-excursion
    (let ((indenter-at-bol) (indenter-at-eol))
      ;; Go back a line and to the first character.
      (forward-line -1)
      (backward-to-indentation 0)

      ;; If the next few characters match one of our magic indenter
      ;; keywords, we want to indent the line we were on originally.
      (when (looking-at (livescript-indenters-bol-regexp))
        (setq indenter-at-bol t))

      ;; If that didn't match, go to the back of the line and check to
      ;; see if the last character matches one of our indenter
      ;; characters.
      (when (not indenter-at-bol)
        (end-of-line)

        ;; Optimized for speed - checks only the last character.
        (let ((indenters livescript-indenters-eol))
          (while indenters
            (if (and (char-before) (/= (char-before) (car indenters)))
                (setq indenters (cdr indenters))
              (setq indenter-at-eol t)
              (setq indenters nil)))))

      ;; If we found an indenter, return `t'.
      (or indenter-at-bol indenter-at-eol))))

(defun livescript-previous-line-is-comment ()
  "Return t if the previous line is a LiveScript comment."
  (save-excursion
    (forward-line -1)
    (livescript-line-is-comment)))

(defun livescript-line-is-comment ()
  "Return t if the current line is a LiveScript comment."
  (save-excursion
    (backward-to-indentation 0)
    (= (char-after) (string-to-char "#"))))


;; (defun livescript-quote-syntax (n)
;;   "Put `syntax-table' property correctly on triple quote.
;; Used for syntactic keywords.  N is the match number (1, 2 or 3)."
;;   ;; From python-mode...
;;   ;;
;;   ;; Given a triple quote, we have to check the context to know
;;   ;; whether this is an opening or closing triple or whether it's
;;   ;; quoted anyhow, and should be ignored.  (For that we need to do
;;   ;; the same job as `syntax-ppss' to be correct and it seems to be OK
;;   ;; to use it here despite initial worries.)  We also have to sort
;;   ;; out a possible prefix -- well, we don't _have_ to, but I think it
;;   ;; should be treated as part of the string.

;;   ;; Test cases:
;;   ;;  ur"""ar""" x='"' # """
;;   ;; x = ''' """ ' a
;;   ;; '''
;;   ;; x '"""' x """ \"""" x
;;   (save-excursion
;;     (goto-char (match-beginning 0))
;;     (cond
;;      ;; Consider property for the last char if in a fenced string.
;;      ((= n 3)
;;       (let* ((font-lock-syntactic-keywords nil)
;; 	     (syntax (syntax-ppss)))
;; 	(when (eq t (nth 3 syntax))	; after unclosed fence
;; 	  (goto-char (nth 8 syntax))	; fence position
;; 	  ;; (skip-chars-forward "uUrR")	; skip any prefix
;; 	  ;; Is it a matching sequence?
;; 	  (if (eq (char-after) (char-after (match-beginning 2)))
;; 	      (eval-when-compile (string-to-syntax "|"))))))
;;      ;; Consider property for initial char, accounting for prefixes.
;;      ((or (and (= n 2)			; leading quote (not prefix)
;; 	       (not (match-end 1)))     ; prefix is null
;; 	  (and (= n 1)			; prefix
;; 	       (match-end 1)))          ; non-empty
;;       (let ((font-lock-syntactic-keywords nil))
;; 	(unless (eq 'string (syntax-ppss-context (syntax-ppss)))
;; 	  (eval-when-compile (string-to-syntax "|")))))
;;      ;; Otherwise (we're in a non-matching string) the property is
;;      ;; nil, which is OK.
;;      )))

(defun livescript-indent-shift-amount (start end dir)
  "Compute distance to the closest increment of `livescript-tab-width'."
  (let ((min most-positive-fixnum) rem)
    (save-excursion
      (goto-char start)
      (while (< (point) end)
        (let ((current (current-indentation)))
          (when (< current min) (setq min current)))
        (forward-line))
      (setq rem (% min livescript-tab-width))
      (if (zerop rem)
          livescript-tab-width
        (cond ((eq dir 'left) rem)
              ((eq dir 'right) (- livescript-tab-width rem))
              (t 0))))))

(defun livescript-indent-shift-left (start end &optional count)
  "Shift lines contained in region START END by COUNT columns to the left.
If COUNT is not given, indents to the closest increment of
`livescript-tab-width'. If region isn't active, the current line is
shifted. The shifted region includes the lines in which START and
END lie. An error is signaled if any lines in the region are
indented less than COUNT columns."
  (interactive
   (if mark-active
       (list (region-beginning) (region-end) current-prefix-arg)
     (list (line-beginning-position) (line-end-position) current-prefix-arg)))
  (let ((amount (if count (prefix-numeric-value count)
                  (livescript-indent-shift-amount start end 'left))))
    (when (> amount 0)
      (let (deactivate-mark)
        (save-excursion
          (goto-char start)
          ;; Check that all lines can be shifted enough
          (while (< (point) end)
            (if (and (< (current-indentation) amount)
                     (not (looking-at "[ \t]*$")))
                (error "Can't shift all lines enough"))
            (forward-line))
          (indent-rigidly start end (- amount)))))))

(add-to-list 'debug-ignored-errors "^Can't shift all lines enough")

(defun livescript-indent-shift-right (start end &optional count)
  "Shift lines contained in region START END by COUNT columns to the right.
if COUNT is not given, indents to the closest increment of
`livescript-tab-width'. If region isn't active, the current line is
shifted. The shifted region includes the lines in which START and
END lie."
  (interactive
   (if mark-active
       (list (region-beginning) (region-end) current-prefix-arg)
     (list (line-beginning-position) (line-end-position) current-prefix-arg)))
  (let (deactivate-mark
        (amount (if count (prefix-numeric-value count)
                  (livescript-indent-shift-amount start end 'right))))
    (indent-rigidly start end amount)))

;;
;; Define Major Mode
;;

(defun livescript-block-comment-delimiter (match)
  (progn
    (goto-char match)
    (beginning-of-line)
    (add-text-properties (point) (+ (point) 1) `(syntax-table (14 . nil)))))

;; support coffescript block comments
;; examples:
;;   at indent level 0
;;   ###
;;        foobar
;;   ###
;;   at indent level 0 with text following it
;;   ### foobar
;;     moretext
;;   ###
;;   at indent level > 0
;;     ###
;;       foobar
;;     ###
;; examples of non-block comments:
;;   #### foobar
(defun livescript-propertize-function (start end)
  ;; return if we don't have anything to parse
  (unless (>= start end)
    (save-excursion
      (progn
        (goto-char start)
        (let ((match (re-search-forward "^[[:space:]]*###\\([[:space:]]+.*\\)?$" end t)))
          (if match
              (progn
                (livescript-block-comment-delimiter match)
                (goto-char match)
                (forward-line)
                (livescript-propertize-function (point) end))))))))

;;;###autoload
(define-derived-mode livescript-mode prog-mode
  "LiveScript"
  "Major mode for editing LiveScript."

  ;; code for syntax highlighting
  (setq font-lock-defaults '((livescript-font-lock-keywords)))

  ;; treat "_" as part of a word
  (modify-syntax-entry ?_ "w" livescript-mode-syntax-table)

  ;; perl style comment: "# ..."
  (modify-syntax-entry ?# "< b" livescript-mode-syntax-table)
  (modify-syntax-entry ?\n "> b" livescript-mode-syntax-table)
  (make-local-variable 'comment-start)
  (setq comment-start "#")

  ;; single quote strings
  (modify-syntax-entry ?' "\"" livescript-mode-syntax-table)

  ;; (setq font-lock-syntactic-keywords
  ;;       ;; Make outer chars of matching triple-quote sequences into generic
  ;;       ;; string delimiters.
  ;;       ;; First avoid a sequence preceded by an odd number of backslashes.
  ;;       `((,(concat "\\(?:^\\|[^\\]\\(?:\\\\.\\)*\\)" ;Prefix.
  ;;                   "\\(?:\\('\\)\\('\\)\\('\\)\\|\\(?1:\"\\)\\(?2:\"\\)\\(?3:\"\\)\\)")
  ;;          (1 (livescript-quote-syntax 1) nil lax)
  ;;          (2 (livescript-quote-syntax 2))
  ;;          (3 (livescript-quote-syntax 3)))))

  ;; indentation
  (make-local-variable 'indent-line-function)
  (setq indent-line-function 'livescript-indent-line)
  (set (make-local-variable 'tab-width) livescript-tab-width)
  (set (make-local-variable 'syntax-propertize-function) 'livescript-propertize-function)

  ;; imenu
  (make-local-variable 'imenu-create-index-function)
  (setq imenu-create-index-function 'livescript-imenu-create-index)

  ;; no tabs
  (setq indent-tabs-mode nil)
  (setq tab-width livescript-tab-width))

;;
;; Compile-on-Save minor mode
;;

(defvar livescript-cos-mode-line " LS")
(make-variable-buffer-local 'livescript-cos-mode-line)

(define-minor-mode livescript-cos-mode
  "Toggle compile-on-save for livescript-mode.

Add `'(lambda () (livescript-cos-mode t))' to `livescript-mode-hook' to turn
it on by default."
  :group 'livescript-cos :lighter livescript-cos-mode-line
  (cond
   (livescript-cos-mode
    (add-hook 'after-save-hook 'livescript-compile-file nil t))
   (t
    (remove-hook 'after-save-hook 'livescript-compile-file t))))

(provide 'livescript-mode)

;;
;; On Load
;;

;; Run livescript-mode for files ending in .livescript.
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.ls\\'" . livescript-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("Slakefile\\'" . livescript-mode))
;;; livescript-mode.el ends here
