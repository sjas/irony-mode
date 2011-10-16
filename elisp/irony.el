;;; irony.el --- C based language parsing facilities with Clang (libclang).

;; Copyright (C) 2011  Guillaume Papin

;; Author: Guillaume Papin <guillaume.papin@epitech.eu>
;; Keywords: c, convenience, tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This file provide `irony-mode' a minor mode for C, C++ (eventually
;; Objective C and Objective C++). This minor mode does nothing alone
;; in buffers where it's activated.
;;
;; TODO:
;; - explain `irony-mode' in details.
;; - checkdoc
;;

;;; Usage:

;;; Code:

(require 'json)

(eval-when-compile
  (require 'cc-defs)                    ;for `c-save-buffer-state'
  (require 'cl))

(defgroup irony nil
  "C based language comprehension, completion, syntax checking
and more."
  :version "24.0"
  :group 'c)

(defcustom irony-header-directories nil
  "Directories where header files can be found.

Typically each element of this list will be transmitted to the
compile with a \"-I\" prefix.

The value can *also* be a function (called without any arguments)
that return header directories.

.dir-locals.el example:
        ((c++-mode
          (irony-header-directories . (\"../includes\"
                                       \"../utils\"))))

Note: see also `irony-header-directories-root'."
  :type '(choice (repeat string)
                 (function :tag "Function name that can find the\
header directories"))
  :require 'irony
  :group 'irony)
(make-variable-buffer-local 'irony-header-directories)

(defcustom irony-header-directories-root nil
  "If non-nil relative paths in `irony-header-directories' are
made relative to the value of this variable/function."
  :type '(choice (string :tag "the directory path")
                 (function :tag "a function that return the directory path"))
  :require 'irony
  :group 'irony)
(make-variable-buffer-local 'irony-header-directories-root)

(defcustom irony-config-commands nil
  "The value should be either a list of strings or a function
that return a list of strings.

Each string should be a *shell command* that return flags to send
to the compiler, typically the pkg-config commands.

i.e. for a project using the SDL:
        (\"pkg-config --cflags sdl\")"
  :type '(choice (repeat string)
                 (function :tag "Function name that can find the\
header directories"))
  :require 'irony
  :group 'irony)
(make-variable-buffer-local 'irony-config-commands)

(defcustom irony-extra-flags nil
  "The value should be either a list of strings or a function
that return a list of string.

Each string is a flags to send to the Clang parser. Only for
flags that can't fit in `irony-header-directories' or
`irony-config-commands'.

i.e: '(\"-std=c++0x\" \"-DNDEBUG\""
  :type '(choice (repeat string)
                 (function :tag "Function name that can find the\
header directories"))
  :require 'irony
  :group 'irony)
(make-variable-buffer-local 'irony-extra-flags)

(defcustom irony-known-modes '(c++-mode
                               c-mode)
  "List of modes where `irony-mode' can be turn on without
  warnings.

note: `obj-c-mode' would probably fit here but it need to be
tested."
  :type '(repeat symbol)
  :require 'irony
  :group 'irony)

(defcustom irony-lang-option-alist '((c++-mode . "-xc++")
                                     (c-mode   . "-xc"))
  "Association list of major-mode -> lang option to pass to the
  compiler."
  :type '(alist :key-type symbol :value-type string)
  :require 'irony
  :group 'irony)

(defcustom irony-server-executable (or (executable-find "irony-server")
                                       (let ((path (concat (file-name-directory
                                                            (locate-library "irony"))
                                                           "../irony-server")))
                                         (if (file-exists-p path)
                                             (expand-file-name path))))
  "The path where the \"irony-server\" executable can be found."
  :type 'file
  :require 'irony
  :group 'irony)

(defcustom irony-mode-line " ⸮"
  "Text to display in the mode line (actually an irony mark) when
irony mode is on."
  :type 'string
  :require 'irony
  :group 'irony)

(defcustom irony-priority-limit 74
  "The Clang priority threshold to keep a candidate in the
completion list. Smaller values indicate higher-priority (more
likely) completions."
  :type 'integer
  :require 'irony
  :group 'irony)

;; (defcustom irony-completion-function nil
;;   "Function to call when new completion results are received."
;;   :type 'function
;;   :require 'irony
;;   :group 'irony)

;; (defcustom irony-syntax-checking-function nil
;;   "Function to call when a syntax results are received."
;;   :type 'function
;;   :require 'irony
;;   :group 'irony)

;;
;; Internal variables
;;

(defvar irony-process nil
  "The current irony-server process.")

(defconst irony-output-type-dispatching
  ;; '((:completion      . irony-completion-function)
  ;;   (:syntax-checking . irony-syntax-checking-function)))
  '((:completion      . irony-handle-completion)
    (:syntax-checking . irony-handle-syntax-check))
  "Alist of known request type associated to their handler.")

(defconst irony-eot "\n;;EOT\n"
  "The string sent by the server to finish the transmission of a
  message.")

(defconst irony-server-eot "\nEOT\n"
  "The string to send to the server to finish a transmission.")

(defvar irony-num-requests 0
  "The number of current request to the irony process made. When
the value reach 0 it means the temporary file can be deleted.")
(make-variable-buffer-local 'irony-num-requests)

(defvar irony-flags-cache nil
  "Calculating the flags for a buffer can be costly, so after the
  first time we use this variable as value for flags.")
(make-variable-buffer-local 'irony-flags-cache)

(define-minor-mode irony-mode
  ;; FIXME: describe the mode here
  ;; Check if turning off the mode with -1 work.
  "Toggle irony mode.

With no argument, this command toggles the mode. Non-null prefix
argument turns on the mode. Null prefix argument turns off the
mode."
  nil
  irony-mode-line
  '(
    ;; ([(control return)] . irony-complete)
    )
  :group 'irony

  (when irony-mode             ;start irony mode
    ;; If not in a known mode warn the user
    (unless (memq major-mode irony-known-modes)
      (display-warning 'irony
                       "Irony mode is aimed to work with a major \
mode present in `irony-known-modes'.."))
    ;; FIXME: if the process is not found, turn off `irony-mode'.
    (irony-start-process-maybe)))

(defun irony-stop-process ()
  "Stop the irony process."
  (if (not irony-process)
      (message "No irony process running...")
    (delete-process irony-process)
    (setq irony-process nil)))

(defun irony-restart-process ()
  "Restart the irony process."
  (irony-stop-process)
  (irony-start-process-maybe))

(defun irony-start-process-maybe ()
  "Launch the `irony-process' if it's not already started."
  (cond
   ;; Already stated, nothing need to be done
   ((processp irony-process))
   ;; Executable not found or invalid
   ((or (null irony-server-executable)
        (null (file-executable-p irony-server-executable))
        (file-directory-p irony-server-executable))
    (error "Can't start the process `%s'. Please check \
the value of the variable `irony-server-executable'."
           irony-server-executable))
   ;; Try to start the process, let `start-process-shell-command'
   ;; throw an error if something went wrong.
   (t
    ;; Without this the server doesn't work as expected, line
    ;; buffering and cie...
    ;;                  |
    ;;                  V
    ;;     ~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    (let ((process-connection-type  nil))
      (setq irony-process (start-process-shell-command
                           "Irony"           ;process name
                           "*Irony*"         ;buffer
                           (irony-command))) ;command
      (set-process-query-on-exit-flag irony-process nil)
      (set-process-sentinel irony-process 'irony-sentinel)
      (set-process-filter irony-process 'irony-handle-output)))))

(defun irony-command ()
  "Shell command used to start the irony-server process."
  (format "\"%s\" 2>> %s/irony.$$.log"
          irony-server-executable
          temporary-file-directory))

(defun irony-sentinel (process event)
  "Watch the activity of irony process."
  ;; FIXME: turn off `irony-mode' in all buffer ?
  (let ((status (process-status process)))
    (when (memq status '(exit signal closed failed))
      (message "irony process stopped..."))))

;; FIXME: search for one or MORE results in the response, for example
;; a completion request can return syntax error informations found
;; during the search of completion results.
(defun irony-handle-output (process output)
  "Handle an output from the `irony-process'.

If a complete response is present in the irony process buffer the
variable `irony-output-type-dispatching' is used in order to find
the action to do with the :type key in the request."
  ;; If with OUTPUT we get a complete answer, RESPONSE will be
  ;; non-nil.
  (let ((pbuf (process-buffer process))
        response)
    ;; Add to process buffer
    (when (buffer-live-p pbuf)
      (with-current-buffer pbuf
        (save-excursion
          (goto-char (process-mark process))
          (insert output)
          (set-marker (process-mark process) (point))
          ;; Check if the message is complete based on `irony-eot'
          (goto-char (point-min))
          (when (search-forward irony-eot nil t)
            (setq response (buffer-substring (point-min) (point)))
            (delete-region (point-min) (point))
            (let ((reason (unsafep response)))
              (when reason
                (setq response nil)
                (error "Unsafe data received by the irony process\
 (request skipped): %s." reason)))))
        (goto-char (process-mark process))))
    (when (stringp response)
      (let* ((sexp (read response))
             (type (plist-get sexp :type))
             (buffer-file (plist-get sexp :buffer))
             (buffer (if buffer-file (get-file-buffer buffer-file)))
             (handler (cdr (assq type irony-output-type-dispatching))))
        (if buffer
            (irony-pop-request buffer))
        (if (null handler)
            (error "Irony process received an unknown request. \
Request was \"%s\"." response)
          (cond
           ((functionp handler)
            (funcall handler sexp))
           (handler
            (warn "The value of %s is not set correctly, function \
expected got: %s." (symbol-name handler) handler))))))))

(defun irony-push-request (buffer)
  "Increment the request count `irony-num-requests' in the given
buffer and write the buffer content in a temporary file."
  (with-current-buffer buffer
    (setq irony-num-requests (1+ irony-num-requests))
    (write-region nil nil (irony-temp-filename) nil -1)))

(defun irony-pop-request (buffer)
  "Decrement the request count `irony-num-requests' in the given
buffer, if the value of zero is reached delete the temporary file
associated to the buffer if any."
  (with-current-buffer buffer
    (when (zerop (setq irony-num-requests (1- irony-num-requests)))
      (let ((temp-file (irony-temp-filename)))
        (if (file-exists-p temp-file)
            (delete-file temp-file nil))))))

(defun irony-buffer-identifier (&optional buffer)
  "Get the expanded buffer filename if any. If there is no
filename associated to this buffer return the name of the
buffer."
  (or (expand-file-name (buffer-file-name buffer))
      (buffer-name buffer) "killed-buffer"))

(defun irony-temp-filename (&optional buffer)
  "Return the temporary filename associated to BUFFER (the
current buffer by default).

The file is created under `temporary-file-directory' in order to
avoid polluting the working directory."
  (let ((file (irony-buffer-identifier buffer)))
    ;; Partially stolen from files.el `make-backup-file-name-1'
    (concat
     temporary-file-directory
     (subst-char-in-string ?/ ?! (replace-regexp-in-string "!" "!!" file)))))

(defun irony-send-request (type data buffer)
  "Send a request of type TYPE to the irony process.

The argument DATA is a plist of data that complete the
request, example:
        (:file \"/tmp/foo.cpp\" :line 42 :column 4)

If non-nil BUFFER will be added to the target buffer, that mean
when the answer will be received we will be able to retrieve the
buffer who sent the request."
  (let ((request (list :request type :data data)))
    (when buffer
      (irony-push-request buffer)
      (setq request (plist-put request :buffer (irony-buffer-identifier
                                                buffer))))
    (process-send-string irony-process (concat (json-encode request)
                                               irony-server-eot))))

(defun irony-wait-request-answer (sym)
  "Loop until the SYM value became non nil, SYM value should
change in the irony process filter, when a request is completed
the flag is set to a non nil value (probably the request datas).

Once the symbol value is non nil it's value is returned."
  ;; Wait for the completion to be completed or the death of the
  ;; process (condition partially stolen from "network-stream.el".
  ;; FIXME: Emacs can wait indefinitly in this loop if something is
  ;; wrong with the request ?
  (while (and (null (symbol-value sym))
              (memq (process-status irony-process) '(open run)))
    (accept-process-output irony-process 0.05))
  (symbol-value sym))

(defun irony-get-flags (&optional buffer)
  "Find the compiler flags required to parse the content of
  BUFFER (by default the current buffer).

The value returned is a list of flags where the variable
  `irony-header-directories', `irony-config-commands',
  `irony-lang-option-alist' and `irony-extra-flags' will be
  used (check the documentation of the variables for more
  informations).

Note: In addition to `irony-header-directories' the directory of
BUFFER will be added for the include directives (this is due to
the use of temporary file where the headers present in the same
directory of the orignal file couldn't be found )."
  (with-current-buffer (or buffer (current-buffer))
    (or irony-flags-cache
        (let ((lang-flag (irony-language-option-flag)))
          (setq irony-flags-cache
                (append
                 (if buffer-file-name
                     (list (concat "-I" (file-name-directory
                                         (expand-file-name buffer-file-name)))))
                 (irony-include-flags
                  (if (functionp irony-header-directories-root)
                      (funcall irony-header-directories-root)
                    irony-header-directories-root))
                 (if (functionp irony-extra-flags)
                     (funcall irony-extra-flags)
                   irony-extra-flags)
                 (irony-parse-config-flags)
                 (if lang-flag (list lang-flag))))))))

(defun irony-include-flags (&optional root-directory)
  "Parse a list of header directories `irony-header-directories'
into a list of \"-Idir\" flags to send to the compiler. Relative
path are relative to the ROOT-DIRECTORY if given.

example without ROOT-DIRECTORY:
        (\"utils\" \"/my/include/directory\")
        became:
        (\"-Iutils\" \"-I/my/include/directory\")

example with ROOT-DIRECTORY equal to \"/home/user/project/my_project\":
        (\"utils\" \"/my/include/directory\")
        became:
        (\"-I/home/user/project/my_project/utils\" \"-I/my/include/directory\")"
  (mapcar (lambda (path)
            (concat "-I" (expand-file-name path root-directory)))
          (if (functionp irony-header-directories)
              (funcall irony-header-directories)
            irony-header-directories)))

(defun irony-parse-config-flags ()
  "Parse a list of pkg-config like commands
`irony-config-commands' into a list of arguments to send to the
compiler.

example:
        (\"pkg-config --cflags sdl\")
        became:
        (\"-D_GNU_SOURCE=1\" \"-D_REENTRANT\" \"-I/usr/include/SDL\")
"
  (let ((commands (if (functionp irony-config-commands)
                      (funcall irony-config-commands)
                    irony-config-commands)))
    (split-string (mapconcat 'shell-command-to-string commands " "))))

(defun irony-language-option-flag ()
  "Find the language for filename based on the major mode. (the
-x option of the compiler)."
  (cdr-safe (assq major-mode irony-lang-option-alist)))

(defmacro irony-without-narrowing (&rest body)
  "Remove the effect of narrowing for the current buffer.

Note: If `save-excursion' is needed for body, it should be used
before calling that macro."
  (declare (indent 0) (debug t))
  `(save-restriction
     (widen)
     (progn ,@body)))

(defun irony-point-location (point)
  "Return a cons of the following form: (line . column)
corresponding to POS. The narrowing is skipped temporary."
  (save-excursion
    (goto-char point)
    (irony-without-narrowing
      (cons (line-number-at-pos) (1+ (current-column))))))


;;
;; Irony utility functions
;;

;; TODO:
;; Interactive with completion (see `completion-read')
(defun irony-enable (modules)
  "Load one or more modules for Irony. (this is simply a helper function for
modules that respect the following contract:
- provide irony-MODULE-NAME
- defun irony-MODULE-NAME-enable
- defun irony-MODULE-NAME-disable"
  (dolist (module (if (listp modules) modules (list modules)))
    (require (intern (concat "irony-" (symbol-name module))))
    (funcall (intern (concat "irony-" (symbol-name module) "-enable")))))

(defun irony-disable (modules)
  "Unload one or more modules for Irony. (this is simply a helper function for
modules that respect the following contract:
- provide irony-MODULE-NAME
- defun irony-MODULE-NAME-enable
- defun irony-MODULE-NAME-disable"
  (dolist (module (if (listp modules) modules (list modules)))
    (funcall (intern (concat "irony-" (symbol-name module) "-disable")))))

;; ! Irony utility functions


;;
;; Completions functions
;;

(defvar irony-last-completion nil
  "If non nil contain the last completion answer received by the
  server (internal variable).")

(defun irony-handle-completion (data)
  "Handle a completion request from the irony process,
actually because the code completion is not 'asynchronous' this
function only set the variable `irony-last-completion'."
  (setq irony-last-completion data))

(defun irony-complete-detailed (&optional pos)
  "Return a detailed list of completion available at POS."
  ;; FIXME: explain what a detailed result is.
  (let* ((location (irony-point-location (or pos (point))))
         (request-data (list (cons :file (irony-temp-filename))
                             (cons :flags (irony-get-flags))
                             (cons :line (car location))
                             (cons :column (cdr location)))))
    (setq irony-last-completion nil)
    (irony-send-request :complete request-data (current-buffer)))
  (loop with answer = (irony-wait-request-answer 'irony-last-completion)
        for result in (plist-get answer :results)
        for priority = (or (plist-get result :priority) irony-priority-limit)
        when (< priority irony-priority-limit) collect result))

(defsubst irony-completion-result-typed-text (result)
  "Get the :typed-text part of a completion RESULT."
  (cdr-safe (assoc :typed-text (plist-get result :result))))

(defun irony-complete-simple (&optional pos)
  "Return a list of completion string available at POS (point by
default)."
  (interactive)
  (loop for result in (irony-complete-detailed pos)
        for typed-text = (irony-completion-result-typed-text result)
        collect typed-text into completions
        finally return (delete-dups completions)))

(defun irony-get-completion-point ()
  "Return the point where the completion should start from the
current point. If no completion can be used in the current
context return NIL.

Note: This function try to return the point only in case where it
seems to be interesting and not too slow to show the completion
under point. If you want to have the completion *explicitly* you
should use `irony-get-completion-point-anywhere'."
  ;; Try different possibilities...
  (or
   ;; - Object member access: '.'
   ;; - Pointer member access: '->'
   ;; - Scope operator: '::'
   (if (re-search-backward "\\(?:\\.\\|->\\|::\\)\\(\\(?:[_a-zA-Z][_a-zA-Z0-9]*\\)?\\)\\=" nil t)
       (let ((point (match-beginning 1)))
         ;; fix floating number literals (the prefix tried to complete
         ;; the following "3.[COMPLETE]")
         (unless (re-search-backward "[^_a-zA-Z0-9][[:digit:]]+\\.[[:digit:]]*\\=" nil t)
           point)))
   ;; Initialization list (use the syntactic informations partially
   ;; stolen from `c-show-syntactic-information')
   ;; A::A() : [complete], [complete]
   (if (re-search-backward "[,:]\\s-*\\(\\(?:[_a-zA-Z][_a-zA-Z0-9]*\\)?\\)\\=" nil t)
       (let* ((point (match-beginning 1))
              (c-parsing-error nil)
              (syntax (if (boundp 'c-syntactic-context)
                          c-syntactic-context
                        (c-save-buffer-state nil (c-guess-basic-syntax)))))
         (if (or (assoc 'member-init-intro (c-guess-basic-syntax))
                 (assoc 'member-init-cont (c-guess-basic-syntax)))
             ;; Check if were are in an argument list
             ;; without this when we have:
             ;;  A::A() : foo(bar, []
             ;; the completion is triggered.
             (if (eq (car (syntax-ppss)) 0) ;see [[info:elisp#Parser State]]
                 point))))
   ;; switch/case statements, complete after the case
   (if (re-search-backward "[ \n\t\v\r\f;{]case\\s-+\\(\\(?:[_a-zA-Z][_a-zA-Z0-9]*\\)?\\)\\=" nil t)
       (match-beginning 1))))

(defun irony-get-completion-point-anywhere ()
  "Return the completion point for the current context, contrary
to `irony-get-completion' a point will be returned every times."
  (or
   (if (re-search-backward "[^_a-zA-Z0-9]\\([_a-zA-Z][_a-zA-Z0-9]*\\)\\=" nil t)
       (match-beginning 1))
   (point)))

;; ! Completion functions


;;
;; Syntax checking functions
;;

(defvar irony-last-syntax-check nil
  "Contain the last syntax checking made by the Irony
  server (internal variable).")

(defun irony-handle-syntax-check (data)
  "Function called when a syntax checking answer is received."
  (setq irony-last-syntax-check data))

(defun irony-syntax-check (&optional buffer)
  "Return a list of diagnostics found during the parsing of the
BUFFER translation unit."
  ;; FIXME: explain the content of the returned value.
  (let ((request-data (list (cons :file (irony-temp-filename))
                            (cons :flags (irony-get-flags)))))
    (setq irony-last-syntax-check nil)
    (irony-send-request :syntax-check request-data (or buffer (current-buffer))))
  (irony-wait-request-answer 'irony-last-syntax-check))

;; ! Syntax checking functions

(provide 'irony)
;;; irony.el ends here