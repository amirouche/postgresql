;;; -*- mode:scheme; coding:utf-8; -*-
;;;
;;; postgresql/apis.sld - PostgreSQL API
;;;  
;;;   Copyright (c) 2014  Takashi Kato  <ktakashi@ymail.com>
;;;   
;;;   Redistribution and use in source and binary forms, with or without
;;;   modification, are permitted provided that the following conditions
;;;   are met:
;;;   
;;;   1. Redistributions of source code must retain the above copyright
;;;      notice, this list of conditions and the following disclaimer.
;;;  
;;;   2. Redistributions in binary form must reproduce the above copyright
;;;      notice, this list of conditions and the following disclaimer in the
;;;      documentation and/or other materials provided with the distribution.
;;;  
;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
;;;   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;;;   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;;   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;;   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;;   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;  

(define-library (postgresql apis)
  (export make-postgresql-connection
	  postgresql-connection?
	  postgresql-open-connection!
	  postgresql-login!
	  postgresql-terminate!

	  ;; simple query
	  postgresql-query?
	  postgresql-query-descriptions
	  postgresql-execute-sql!

	  ;; prepared statement
	  postgresql-prepared-statement?
	  postgresql-prepared-statement
	  postgresql-prepared-statement-sql ;; for observation
	  postgresql-bind-parameters!
	  postgresql-execute!
	  postgresql-close-prepared-statement!

	  ;; configuration parameter
	  *postgresql-maximum-results*

	  postgresql-fetch-query!
	  )
  (import (scheme base)
	  (scheme write)
	  (scheme char)
	  (postgresql messages)
	  (digest md5)
	  (misc socket)
	  (misc bytevectors))
  (begin
    ;; default 50
    (define *postgresql-maximum-results* (make-parameter 50))

    (define-record-type postgresql-connection 
      (make-postgresql-connection host port database username password)
      postgresql-connection?
      (host     postgresql-connection-host)
      (port     postgresql-connection-port)
      (database postgresql-connection-database)
      (username postgresql-connection-username)
      (password postgresql-connection-password)
      ;; after it's opened
      (socket   postgresql-connection-socket postgresql-connection-socket-set!)
      ;; 
      (sock-in  postgresql-connection-sock-in
		postgresql-connection-sock-in-set!)
      (sock-out postgresql-connection-sock-out 
		postgresql-connection-sock-out-set!)
      (params   postgresql-connection-params postgresql-connection-params-set!)
      (id       postgresql-connection-id postgresql-connection-id-set!)
      (key      postgresql-connection-key postgresql-connection-key-set!)
      (counter  postgresql-connection-counter
		postgresql-connection-counter-set!))

    ;; gensym would be easier but not portable...
    (define (generate-unique-string conn)
      (let ((counter (postgresql-connection-counter conn)))
	(postgresql-connection-counter-set! conn (+ counter 1))
	(string-append (postgresql-connection-username conn)
		       (number->string (postgresql-connection-id conn))
		       (number->string counter))))
		     
    (define (postgresql-open-connection! conn)
      ;; TODO check if connection is already open.
      ;;  - should we re-open? or keep it?
      ;;  - probably re-open is safer since we don't have 'select'
      (let ((s (make-client-socket (postgresql-connection-host conn)
				   (postgresql-connection-port conn))))
	(postgresql-connection-socket-set! conn s)
	(postgresql-connection-sock-in-set! conn (socket-input-port s))
	(postgresql-connection-sock-out-set! conn (socket-output-port s))
	(postgresql-connection-counter-set! conn 0)
	conn))

    (define (close-conn conn)
      (socket-close (postgresql-connection-socket conn)))

    ;; can be used anywhere
    (define (read-null-terminated-string params i)
      (let ((out (open-output-string)))
	(let loop ((i i))
	  (let ((b (bytevector-u8-ref params i)))
	    (if (zero? b)
		(values (+ i 1) (get-output-string out))
		(begin
		  (write-char (integer->char b) out)
		  (loop (+ i 1))))))))

    (define (postgresql-login! conn)
      (define read-string read-null-terminated-string)
      (define (store-params params)
	(define len (bytevector-length params))
	;; convert it to alist ((name . value)) 
	;; name is symbol, value is string
	(let loop ((i 0) (r '()))
	  (let*-values (((next name) (read-string params i))
			((next value) (read-string params next)))
	    (if (= len next)
		(postgresql-connection-params-set! conn r)
		(loop next (cons (cons (string->symbol name) value) r))))))
      (define (next in)
	(let-values (((code payload) (postgresql-read-response in)))
	  (case code
	    ((#\K)
	     (let ((id (bytevector-u32-ref-be payload 0))
		   (key (bytevector-u32-ref-be payload 4)))
	       (postgresql-connection-id-set! conn id)
	       (postgresql-connection-key-set! conn key)
	       (next in)))
	    ((#\S) 
	     (store-params payload)
	     (next in))
	    ((#\N)
	     (let ((code (bytevector-u8-ref payload 0)))
	       ;; TODO how should we treat this?
	       (unless (zero? code)
		 (write-string (utf8->string payload 1) (current-error-port))
		 (newline (current-error-port)))
	       (next in)))
	    ((#\Z) #t))))

      (let ((in   (postgresql-connection-sock-in conn))
	    (out  (postgresql-connection-sock-out conn))
	    (user (postgresql-connection-username conn))
	    (pass (postgresql-connection-password conn))
	    (database (let ((d (postgresql-connection-database conn)))
			(if d (list (cons "database" d)) '()))))
	(postgresql-send-startup-message out (cons (cons "user" user) database))
	;; authenticate
	(let loop ((first #t))
	  ;; concat('md5', md5(concat(md5(concat(password, username)),
	  ;;                          random-salt)))
	  ;; PostgreSQL md5 function returns hex string in small letters,
	  ;; so we need to do some trick here.
	  ;; it horribly sucks but it's inevitable...
	  (define (construct payload)
	    (let* ((pu5 (md5 (string-append pass user)))
		   (pus5 (md5 (bytevector-append (string->utf8 pu5) 
						 (bytevector-copy payload 4)))))
	      (string-append "md5" pus5)))
	  (define (send-password conn payload)
	    (unless first
	      (error "postgresql-login!: failed to login"))
	    (if (= (bytevector-length payload) 4)
		(postgresql-send-password-message out pass)
		(postgresql-send-password-message out (construct payload))))
	  (let-values (((code payload) (postgresql-read-response in)))
	    (unless (char=? code #\R)
	      (close-conn conn)
	      (error "postgresql-login!: server respond unexpected message"
		     code))
	    ;; get content
	    (case (bytevector-u32-ref-be payload 0)
	      ((0) (next in)) ;; ok
	      ((3) (send-password conn payload) (loop #f))
	      ((5) (send-password conn payload) (loop #f))
	      (else 
	       (close-conn conn)
	       (error "postgresql-login!: unsupported login method")))))))

    (define (postgresql-terminate! conn)
      (let ((out (postgresql-connection-sock-out conn)))
	(postgresql-send-terminate-message out)
	(close-conn conn)))

    (define-record-type postgresql-query
      (make-postgresql-query connection buffer cursor eoq)
      postgresql-query?
      (connection   postgresql-query-connection)
      (descriptions postgresql-query-descriptions 
		    postgresql-query-descriptions-set!)
      (buffer       postgresql-query-buffer postgresql-query-buffer-set!)
      (cursor       postgresql-query-cursor postgresql-query-cursor-set!)
      ;; end of query
      (eoq          postgresql-query-eoq 
		    postgresql-query-eoq-set!))

    ;; parse description to a vector
    ;; a description:
    ;;  #(name table-id column-num type-id type-size type-modifier format-code)
    (define (parse-row-description payload k)
      (define read-string read-null-terminated-string)
      (let* ((n (bytevector-u16-ref-be payload 0))
	     (vec (make-vector n #f)))
	(let loop ((offset 2) (i 0))
	  (if (= i n)
	      (k vec)
	      (let-values (((next name) (read-string payload offset)))
		(let ((table-id   (bytevector-u32-ref-be payload next))
		      (column-num (bytevector-u16-ref-be payload (+ next 4)))
		      (type-id    (bytevector-u32-ref-be payload (+ next 6)))
		      (type-size  (bytevector-u16-ref-be payload (+ next 10)))
		      (type-mod   (bytevector-u32-ref-be payload (+ next 12)))
		      (fmt-code   (bytevector-u16-ref-be payload (+ next 16))))
		  (vector-set! vec i (vector name table-id column-num type-id
					     type-size type-mod fmt-code))
		  (loop (+ next 18) (+ i 1))))))))

    ;; this is very inefficient one, do not use for
    ;; big query like more than 10000 or so
    (define (postgresql-execute-sql! conn sql)
      (let ((out (postgresql-connection-sock-out conn))
	    (in  (postgresql-connection-sock-in conn)))
	(postgresql-send-query-message out sql)
	;; get 
	(let loop ((r #t) (rows '()))
	  (let-values (((code payload) (postgresql-read-response in)))
	    (case code
	      ((#\C)           ;; Close
	       (cond ((postgresql-query? r)
		      (postgresql-query-eoq-set! r #t)
		      (loop r rows))
		     (else
		      ;; create query
		      (loop (make-postgresql-query conn #f #f #t) rows))))
	      ((#\Z)           ;; ReadyForQuery
	       (when (postgresql-query? r)
		 (postgresql-query-buffer-set! r (list->vector (reverse rows)))
		 (postgresql-query-cursor-set! r 0))
	       r)
	      ((#\T)	       ;; RowDescription
	       ;; TODO should we store records?
	       (let ((query (make-postgresql-query conn #f #f #f)))
		 (loop (parse-row-description payload
			(lambda (vec)
			  (postgresql-query-descriptions-set! query vec)
			  query)) rows)))
	      ((#\D)
	       (let ((rows (if (postgresql-query? r)
			       (cons (parse-record r payload) rows)
			       rows)))
		 (loop r rows)))
	      (else (loop r rows)))))))

    (define-record-type postgresql-statement
      (make-postgresql-prepared-statement connection sql name)
      postgresql-prepared-statement?
      (connection postgresql-prepared-statement-connection)
      (sql        postgresql-prepared-statement-sql)
      ;; prepared statement name
      (name       postgresql-prepared-statement-name
		  postgresql-prepared-statement-name-set!)
      ;; underling portal name
      #;
      (portal     postgresql-prepared-statement-portal
		  postgresql-prepared-statement-portal-set!)
      (parameters postgresql-prepared-statement-parameters
		  postgresql-prepared-statement-parameters-set!)
      ;; object id of the parameter data type
      (oids       postgresql-prepared-statement-oids
		  postgresql-prepared-statement-oids-set!)
      ;; column descriptions
      (descriptions postgresql-prepared-statement-descriptions
		    postgresql-prepared-statement-descriptions-set!))

    (define (init-prepared-statement prepared)
      (define conn (postgresql-prepared-statement-connection prepared))
      (define (parse-oids payload)
	(let ((n (bytevector-u16-ref-be payload 0)))
	  (let loop ((offset 2) (r '()) (i 0))
	    (if (= i n)
		(reverse r) ;; keep it as a list for convenience.
		(let ((oid (bytevector-u32-ref-be payload offset)))
		  (loop (+ offset 4) (cons oid r) (+ i 1)))))))
      (let ((out (postgresql-connection-sock-out conn))
	    (in  (postgresql-connection-sock-in conn))
	    (sql (postgresql-prepared-statement-sql prepared))
	    (name (generate-unique-string conn)))
	(postgresql-send-parse-message out name sql '())
	(postgresql-prepared-statement-name-set! prepared name)
	;; get description
	(postgresql-send-describe-message out name #\S)
	;; now flush
	(postgresql-send-flush-message out)
	;; handle responses
	(let-values (((code payload) (postgresql-read-response in)))
	  (unless (char=? code #\1)
	    (error "postgresql-prepared-statement: prepared statement" sql)))
	(let-values (((code payload) (postgresql-read-response in)))
	  (unless (char=? code #\t)
	    (error "postgresql-prepared-statement: parameter description" 
		   code))
	  (postgresql-prepared-statement-oids-set! prepared 
						   (parse-oids payload)))
	(let-values (((code payload) (postgresql-read-response in)))
	  (cond ((char=? code #\T)
		 (parse-row-description 
		  payload 
		  (lambda (vec)
		    (postgresql-prepared-statement-descriptions-set!
		     prepared vec)
		    prepared)))
		((char=? code #\n)  ;; NoData
		 (postgresql-prepared-statement-descriptions-set! prepared #f)
		 prepared)
		(else
		 (error 
		  "postgresql-prepared-statement: failed to get description"
		  code))))))

    ;; for god sake....
    (define (postgresql-prepared-statement conn sql)
      (make-postgresql-prepared-statement conn sql #f))

    (define (postgresql-bind-parameters! prepared . params)
      (define conn (postgresql-prepared-statement-connection prepared))
      (define (check prepared)
	;; i have no idea how to re-use prepared statement
	;; for some reason it always returns 42P03 error.
	;; it requires a portal (cursor) but it won't recreate
	;; or something when we try to re-use...SUCKS!!!
	(when (postgresql-prepared-statement-name prepared)
	  (postgresql-close-prepared-statement! prepared))
	(init-prepared-statement prepared))
      ;; need to be checked
      (check prepared)
      (let ((out (postgresql-connection-sock-out conn))
	    (in  (postgresql-connection-sock-in conn))
	    (name (postgresql-prepared-statement-name prepared)))
	;; to create the same portal if needed
	(postgresql-send-bind-message out name name params '())
	(postgresql-send-flush-message out)
	;; handle response
	(let-values (((code payload) (postgresql-read-response in)))
	  ;; BindComplete(#\2)
	  (unless (char=? code #\2)
	    (error "postgresql-execute! failed to execute" code)))
	(postgresql-prepared-statement-parameters-set! prepared params)
	prepared))

    (define (postgresql-execute! prepared)
      (define conn (postgresql-prepared-statement-connection prepared))
      (let ((out (postgresql-connection-sock-out conn))
	    (in  (postgresql-connection-sock-in conn))
	    (name (postgresql-prepared-statement-name prepared))
	    ;; (params (postgresql-prepared-statement-parameters prepared))
	    (maxnum (*postgresql-maximum-results*)))
	(postgresql-send-execute-message out name maxnum)
	(postgresql-send-flush-message out)
	;; store it in the buffer
	(let ((q (make-postgresql-query conn (make-vector maxnum) 0 #f)))
	  (postgresql-query-descriptions-set! q
	   (postgresql-prepared-statement-descriptions prepared))
	  (fill-buffer q))))

    (define (postgresql-close-prepared-statement! prepared)
      (define conn (postgresql-prepared-statement-connection prepared))
      (let ((out (postgresql-connection-sock-out conn))
	    (in  (postgresql-connection-sock-in conn))
	    (name (postgresql-prepared-statement-name prepared)))
	(postgresql-send-close-message out #\S name)
	;; do we need this?
	(postgresql-send-close-message out #\P name)
	(postgresql-send-flush-message out)
	(let-values (((code payload) (postgresql-read-response in)))
	  (unless (char=? code #\3)
	    (error "postgresql-close-prepared-statement! failed to close"
		   code prepared)))
	(let-values (((code payload) (postgresql-read-response in)))
	  (unless (char=? code #\3)
	    (error "postgresql-close-prepared-statement! failed to close"
		   code prepared)))
	(postgresql-prepared-statement-name-set! prepared #f)))

    (define (parse-record query payload)
      (define (read-fix payload offset size)
	(let ((end (+ offset size)))
	  (values end (bytevector-copy payload offset end))))

      (define (convert value type)
	;; i need something...
	(case type
	  ;; integer
	  ((23) (string->number (utf8->string value)))
	  ;; varchar
	  ((1043) (utf8->string value))
	  ;; else (just return for now)
	  (else value)))

      (let* ((n (bytevector-u16-ref-be payload 0))
	     (vec (make-vector n #f))
	     (desc (postgresql-query-descriptions query)))
	(let loop ((offset 2) (i 0))
	  (if (= i n)
	      vec
	      (let ((size (bytevector-u32-ref-be payload offset))
		    (type (vector-ref (vector-ref desc i) 3))
		    (offset (+ offset 4)))
		;; I hope this is the only negative number
		;; or should we check if the most significat bit is set?
		(let-values (((offset value) (read-fix payload offset size)))
		  (vector-set! vec i (convert value type))
		  (loop offset (+ i 1))))))))

    (define (fill-buffer query)
      (define conn (postgresql-query-connection query))
      (define in   (postgresql-connection-sock-in conn))
      (define buffer (postgresql-query-buffer query))
      (define len (vector-length buffer))
      ;; init cursor
      (postgresql-query-cursor-set! query 0)
      (let loop ((i 0))
	(if (= i len)
	    query
	    (let-values (((code payload) (postgresql-read-response in)))
	      (case code
		((#\C) 
		 ;; ok shrink the buffer
		 (postgresql-query-eoq-set! query #t)
		 (postgresql-query-buffer-set! query (vector-copy buffer 0 i))
		 query)
		((#\Z) query)
		((#\D) 
		 (vector-set! buffer i (parse-record query payload))
		 (loop (+ i 1)))
		(else 
		 (error "postgresql-fetch-query!: unexpected code" code)))))))

    (define (postgresql-fetch-query! query)
      (define buffer (postgresql-query-buffer query))
      (define cursor (postgresql-query-cursor query))
      (cond ((< cursor (vector-length buffer))
	     (postgresql-query-cursor-set! query (+ cursor 1))
	     (vector-ref buffer cursor))
	    ((postgresql-query-eoq query) #f)
	    (else (postgresql-fetch-query! (fill-buffer query)))))

    )
)