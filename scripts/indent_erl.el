(setq-default indent-tabs-mode nil)

(defvar erlang-dirs '("/usr/local/lib/erlang" "/usr/lib/erlang"))
(defvar erlang-root-dir nil)

(dolist (dir erlang-dirs)
  (when (file-accessible-directory-p dir)
    (setq erlang-root-dir dir)))

(unless erlang-root-dir
  (error "Couldn't find erlang installation. Searched in %s" erlang-dirs))

(defconst erlang-lib-dir
  (concat (file-name-as-directory erlang-root-dir) "lib"))
(defconst erlang-tools-dir
  (and (file-accessible-directory-p erlang-lib-dir)
       (concat (file-name-as-directory erlang-lib-dir)
               (car (directory-files erlang-lib-dir nil "^tools-.*")))))
(defconst erlang-emacs-dir
  (concat (file-name-as-directory erlang-tools-dir) "emacs"))

(defun do-indent (path)
  (princ (format "Indending %s\n" path))

  (find-file path)
  (erlang-mode)
  (indent-region (point-min) (point-max))
  (save-buffer)
  (kill-buffer))

(defun get-paths (l)
  (cdr (cdr (cdr l))))

(when (file-accessible-directory-p erlang-emacs-dir)
  (add-to-list 'load-path erlang-emacs-dir)
  (require 'erlang)
  (dolist (path (get-paths command-line-args))
    (do-indent path)))
