;; -*- lexical-binding: t; -*-

;; Version: 0.1.3
;; Package-Requires: ((emacs "28.2") (compat "29.1.4.0") (dash "2.18.0") (spinner "1.7.4"))

;;; Commentary:

;; Client for AI-powered code completion(s).

;;; Code:

(require 'cl-macs)
(require 'subr-x)

(require 'dash)
(require 'compat)


(defcustom starhugger-api-token nil
  "Hugging Face user access tokens.
Generate yours at https://huggingface.co/settings/tokens."
  :group 'starhugger)

(defcustom starhugger-model-api-endpoint-url
  "https://api-inference.huggingface.co/models/bigcode/starcoder"
  "End point URL to make HTTP request."
  :group 'starhugger)

;;;; Code completion

(defun starhugger--get-all-generated-texts (str)
  (-let* ((parsed (json-parse-string str :object-type 'alist))
          ((_ . err-msg) (and (listp parsed) (assoc 'error parsed))))
    (cond
     (err-msg
      (user-error "%s" err-msg))
     (t
      (-map (lambda (elem) (alist-get 'generated_text elem)) parsed)))))

(defcustom starhugger-generated-buffer (format "*%s*" 'starhugger)
  "Buffer name to log parsed responses."
  :group 'starhugger)

(defcustom starhugger-log-buffer (format " *%s-log*" 'starhugger)
  "Buffer name to log things, hidden by default."
  :group 'starhugger)

(defcustom starhugger-log-time "(%F %T) "
  "Whether to insert this time format before each entry in the log buffer."
  :group 'starhugger)

(defcustom starhugger-max-prompt-length (* 1024 20)
  "Max length of the prompt to send.
\"`inputs` tokens + `max_new_tokens` must be <= 8192\". This
number was determined using trial and errors and is
model-dependant."
  :group 'starhugger)

(defun starhugger--log (&rest args)
  (with-current-buffer (get-buffer-create starhugger-log-buffer)
    (dlet ((inhibit-read-only t))
      (goto-char (point-max))
      (when starhugger-log-time
        (insert (format-time-string starhugger-log-time)))
      (dolist (obj (-interpose " " args))
        (insert (format "%s" obj)))
      (insert "\n"))))

(declare-function spinner-start "spinner")
(defvar starhugger--spinner-added-type nil)
(defun starhugger--spinner-start ()
  (unless starhugger--spinner-added-type
    (require 'spinner)
    (push '(starhugger . ["🤗" "⭐" "🌟" "🌠" "💫"]) spinner-types)
    (setq starhugger--spinner-added-type t))
  (spinner-start 'starhugger 5))

;; WHY isn't this documented?!
(defvar url-http-end-of-headers)

(defcustom starhugger-additional-data-alist
  '((parameters
     (return_full_text . :false) ; don't re-include the prompt
     )
    (options)
    ;;
    )
  "Detailed paramerlist list.
An association list to be converted by `json-serialize'. See
https://huggingface.co/docs/api-inference/detailed_parameters#text-generation-task
for parameters."
  :group 'starhugger)

(defun starhugger--json-serialize (object &rest args)
  "Like (`json-serialize' OBJECT @ARGS).
But prevent errors about multi-byte characters."
  (encode-coding-string (apply #'json-serialize object args) 'utf-8))

(defvar starhugger--last-request nil)
(defvar starhugger-debug nil)

(cl-defun starhugger--request (prompt callback &key data headers method +parameters +options)
  "CALLBACK's arguments: the response's content."
  (-let* ((prompt*
           (substring prompt
                      (max 0 (- (length prompt) starhugger-max-prompt-length))))
          ((&alist 'parameters dynm-parameters 'options dynm-options)
           starhugger-additional-data-alist)
          (data
           (or data
               (starhugger--json-serialize
                `((parameters ,@dynm-parameters ,@+parameters)
                  (options ,@dynm-options ,@+options) (inputs . ,prompt*))))))
    (dlet ((url-request-method (or method "POST"))
           (url-request-data data)
           (url-request-extra-headers
            (or headers
                `(("Content-Type" . "application/json")
                  ,@(and (< 0 (length starhugger-api-token))
                         `(("Authorization" .
                            ,(format "Bearer %s" starhugger-api-token))))
                  ("Connection" . "keep-alive") ; not sure about this yet
                  ))))
      (url-retrieve
       starhugger-model-api-endpoint-url
       (lambda (status)
         (-let* ((content
                  (buffer-substring url-http-end-of-headers (point-max))))
           (setq starhugger--last-request
                 (list
                  :response-content content
                  :send-data data
                  :response-status status))
           (when starhugger-debug
             (starhugger--log
              starhugger--last-request
              :header (buffer-substring (point-min) url-http-end-of-headers)))
           (funcall callback content)))
       nil t))))

(defun starhugger--record-generated
    (prompt parsed-response-list &optional display)
  (with-current-buffer (get-buffer-create starhugger-generated-buffer)
    (when (zerop (buffer-size))
      (insert "Initial model: " starhugger-model-api-endpoint-url "\n"))
    (goto-char (point-max))
    (apply #'insert
           "\n> "
           prompt
           "\n\n"
           (-interpose "\n\n" parsed-response-list))
    (insert "\n"))
  (when display
    (save-selected-window
      (pop-to-buffer starhugger-generated-buffer))))

(defcustom starhugger-strip-prompt-before-insert nil
  "Whether to remove the prompt in the parsed response before inserting.
Enable this when the return_full_text parameter isn't honored."
  :group 'starhugger)

(defcustom starhugger-end-token "<|endoftext|>"
  "End of sentence token."
  :group 'starhugger)

(defcustom starhugger-strip-end-token t
  "Whether to remove `starhugger-end-token' before inserting."
  :group 'starhugger)

(defun starhugger--post-process-content
    (generated-text &optional notify-end prompt)
  (-->
   generated-text
   (if starhugger-strip-prompt-before-insert
       (string-remove-prefix prompt it)
     it)
   (if starhugger-strip-end-token
       (-let* ((end-flag (string-suffix-p starhugger-end-token it)))
         (when (and end-flag notify-end)
           (message "%s received from %s !"
                    starhugger-end-token
                    starhugger-model-api-endpoint-url))
         (if end-flag
             (string-remove-suffix starhugger-end-token it)
           it))
     it)))

(defvar-local starhugger--last-prompt-beg-pos nil)

(defun starhugger--record-last-prompt-beg-pos (pos)
  "Save POS into `starhugger--last-prompt-beg-pos' locally.
The said variable is used to continue completion from there to
the point. Because only some certain keys are used for
continuation, after the next command, set it back to `nil' (1).
Since inserting is asynchronous, the time next command's
insertion happen will happen after (1) so the variable won't stay
`nil' (if inserting happens)."
  (setq starhugger--last-prompt-beg-pos pos)
  (letrec ((fn
            (lambda ()
              (setq starhugger--last-prompt-beg-pos nil)
              (remove-hook 'post-command-hook fn t))))
    (add-hook 'post-command-hook fn nil t)))

(defun starhugger-turn-off-completion-in-region-mode ()
  "Use this when inserting parsed response.
To prevent key binding conflicts such as TAB."
  (completion-in-region-mode 0))

(defvar starhugger-pre-insert-hook
  '(starhugger-turn-off-completion-in-region-mode)
  "Hook run before inserting the parsed response.")

(defcustom starhugger-retry-temperature-range '(0.0 1.0)
  "The lower and upper bound of random temperature when retrying.
A single number means just use it without generating. `nil' means
don't set temperature at all. Set this when the model doesn't
honor use_cache = false."
  :group 'starhugger)

(defvar-local starhugger-query--last-prompt nil)

(defun starhugger--data-for-different-response ()
  `((options (use_cache . :false))
    (parameters
     ,@(and starhugger-retry-temperature-range
            `((temperature .
               ,(cond
                 ((numberp starhugger-retry-temperature-range)
                  starhugger-retry-temperature-range)
                 (t
                  (-let* (((lo hi) starhugger-retry-temperature-range))
                    (--> (cl-random 1.0) (* it (- hi lo)) (+ lo it)))))))))))

(cl-defun starhugger--query-and-record (prompt callback &key display spin force-new &allow-other-keys)
  "Callback is called with the generated text list."
  (-let* ((spin-obj (and spin (starhugger--spinner-start)))
          ((&alist 'options +options 'parameters +parameters)
           (and force-new (starhugger--data-for-different-response))))
    (prog1 (starhugger--request
            prompt
            (lambda (returned)
              (when spin
                (funcall spin-obj))
              (-let* ((gen-texts (starhugger--get-all-generated-texts returned)))
                (funcall callback gen-texts)
                (starhugger--record-generated prompt gen-texts display)))
            :+options +options
            :+parameters +parameters))))

;;;###autoload
(cl-defun starhugger-query (prompt &rest args &key beg-pos end-pos display force-new)
  "Interactive send PROMPT to the model.
Non-nil END-POS (interactively when prefix arg: active region's
end of current point): insert the parsed response there.
BEG-POS:the beginning of the prompt area. Non-nil DISPLAY:
displays the parsed response. FORCE-NEW: disable caching (options
wait_for_model), interactively: PROMPT equals the old one. ARGS
is optional arguments."
  (interactive (-let* ((prompt
                        (read-string "Prompt: "
                                     (and (use-region-p)
                                          (buffer-substring-no-properties
                                           (region-beginning) (region-end))))))
                 (list
                  prompt
                  :end-pos (and current-prefix-arg
                                (if (use-region-p)
                                    (region-end)
                                  (point)))
                  :display t
                  :force-new (equal starhugger-query--last-prompt prompt))))
  (-let* ((pt0 (or end-pos (point)))
          (buf0 (current-buffer))
          (modftick (buffer-modified-tick))
          (callback
           (lambda (gen-texts)
             (with-current-buffer buf0
               (setq starhugger-query--last-prompt prompt)
               (-let* ((pt1 (point))
                       (first-gen-text (cl-first gen-texts))
                       (insert-action
                        (and end-pos
                             (equal modftick (buffer-modified-tick))
                             (lambda ()
                               (run-hooks 'starhugger-pre-insert-hook)
                               (starhugger--record-last-prompt-beg-pos beg-pos)
                               (insert
                                (starhugger--post-process-content
                                 first-gen-text
                                 (or end-pos display) prompt))))))
                 (when insert-action
                   (if (= pt0 pt1)
                       (progn
                         (deactivate-mark)
                         (funcall insert-action))
                     (save-excursion
                       (goto-char pt0)
                       (funcall insert-action)))))))))
    (apply #'starhugger--query-and-record prompt callback :spin t args)))

(defun starhugger--complete-default-beg-position ()
  (-->
   (list
    (bounds-of-thing-at-point 'line)
    (bounds-of-thing-at-point 'paragraph)
    (bounds-of-thing-at-point 'defun))
   (-map #'car it)
   (remove nil it)
   (-min it)))

;;;###autoload
(defun starhugger-complete (&optional beginning)
  "Perform completion using the prompt from BEGINNING to current point.
BEGINNING defaults to start of current line, paragraph or defun,
whichever is the furthest.

Interactively, you may find `starhugger-complete*' performs
better as it takes as much as `starhugger-max-prompt-length'
allows, starting from buffer beginning."
  (interactive)
  (-let* ((beg (or beginning (starhugger--complete-default-beg-position)))
          (prompt (buffer-substring-no-properties beg (point))))
    (starhugger-query prompt :beg-pos beg :end-pos (point))))

;;;###autoload
(defun starhugger-complete* ()
  "Perform completion, use as much text as possible before point as prompt.
Just `starhugger-complete' under the hood."
  (interactive)
  (starhugger-complete (point-min)))

(defun starhugger-complete-from-last-prompt ()
  (interactive)
  (starhugger-complete starhugger--last-prompt-beg-pos))

;;;###autoload
(defun starhugger--continue-complete-menu-item-filter (_)
  (and starhugger--last-prompt-beg-pos #'starhugger-complete-from-last-prompt))

;;;###autoload
(progn
  (define-minor-mode starhugger-global-mode
    "Currently doesn't do very much.
Beside enabling successive completions.
This doesn't trigger loading `starhugger.el'."
    :group 'starhugger
    :global t
    :keymap
    (let* ((tab-item
            `(menu-item "" nil
              :filter starhugger--continue-complete-menu-item-filter)))
      (list
       (cons (kbd "TAB") tab-item) ;
       (cons (kbd "<tab>") tab-item) ;
       ))
    (if starhugger-global-mode
        (progn)
      (progn))))

;;; starhugger.el ends here

(provide 'starhugger)
