#cs
(module parser-builder mzscheme
  
  (require "input-file-parser.ss"
           "table.ss"
           "parser-actions.ss"
           "grammar.ss")
  
  (provide build-parser)
  
  (define (build-parser filename error-expr input-terms start end assocs prods runtime src)
    (let* ((grammar (parse-input start end input-terms assocs prods runtime))
           (table (build-table grammar filename))
           (table-code 
            `((lambda (table-list)
                (let ((v (list->vector table-list)))
                  (let loop ((i 0))
                    (cond
                      ((< i (vector-length v))
                       (let ((vi (vector-ref v i)))
                         (cond
                           ((list? vi) 
                            (vector-set! v i
                                         (cond
                                           ((eq? 's (car vi))
                                            (make-shift (cadr vi)))
                                           ((eq? 'r (car vi))
                                            (make-reduce (cadr vi) (caddr vi) (cadddr vi)))
                                           ((eq? 'a (car vi)) (make-accept)))))))
                       (loop (add1 i)))
                      (else v)))))
              (quote
               ,(map (lambda (action)
                       (cond
                         ((shift? action)
                          `(s ,(shift-state action)))
                         ((reduce? action)
                          `(r ,(reduce-prod-num action)
                              ,(reduce-lhs-num action)
                              ,(reduce-rhs-length action)))
                         ((accept? action)
                          `(a))
                         (else action)))
                     (vector->list table)))))
            
           (num-non-terms (length (grammar-non-terms grammar)))

           (token-code
            `(let ((ht (make-hash-table)))
               (begin
                 ,@(map (lambda (term)
                          `(hash-table-put! ht 
                                            ',(gram-sym-symbol term)
                                            ,(+ num-non-terms (gram-sym-index term))))
                        (grammar-terms grammar))
                 ht)))
           
           (actions-code
            `(vector ,@(map prod-action (grammar-prods grammar))))
           
           (parser-code
            `(letrec ((err ,error-expr)
                      (err-state 0)
                      (table ,table-code)
                      (term-sym->index ,token-code)
                      (actions ,actions-code)
                      (reduce-stack
                       (lambda (s n v)
                         (if (> n 0)
                             (reduce-stack (cddr s) (sub1 n) (cons (cadr s) v))
                             (values s v))))
                      (fix-error
                       (lambda (stack ip get-token)
                         (let remove-states ()
                           (let ((a (find-action stack 'error)))
                             (cond
                               ((shift? a)
				(printf "shift:~a~n" (shift-state a))
                                (set! stack (cons (shift-state a) (cons #f stack))))
                               (else
                                (printf "discard-state:~a~n" (car stack))
                                (cond
                                  ((< (length stack) 3)
                                   (printf "Unable to shift error token~n")
                                   #f)
                                  (else
                                   (set! stack (cddr stack))
                                   (remove-states)))))))
                         (let remove-input ()
                           (let ((a (find-action stack ip)))
                             (cond
                               ((shift? a)
                                (printf "shift:~a~n" (shift-state a))
                                (cons (shift-state a)
                                      (cons (if (token? ip)
                                                (token-value ip)
                                                #f)
                                            stack)))
                               (else
                                (printf "discard-input:~a~n" (if (token? ip)
                                                                 (token-name ip)
                                                                 ip))
                                (set! ip (get-token))
                                (remove-input)))))))
                      
                      (find-action
                       (lambda (stack tok)
                         (array2d-ref table 
                                      (car stack)
                                      (hash-table-get term-sym->index
                                                      (if (token? tok)
                                                          (token-name tok)
                                                          tok)
                                                      err)))))
               (lambda (get-token)
                 (let loop ((stack (list 0))
                            (ip (get-token)))
                   (display stack)
                   (newline)
                   (display (if (token? ip) (token-name ip) ip))
                   (newline)
                   (let ((action (find-action stack ip)))
                     (cond
                       ((shift? action)
                        (printf "shift:~a~n" (shift-state action))
                        (let ((val (if (token? ip)
                                       (token-value ip)
                                       #f)))
                          (loop (cons (shift-state action) (cons val stack))
                                (get-token))))
                       ((reduce? action)
                        (printf "reduce:~a~n" (reduce-prod-num action))
                        (let-values (((new-stack args)
                                      (reduce-stack stack 
                                                    (reduce-rhs-length action)
                                                    null)))
                          (let* ((A (reduce-lhs-num action))
                                 (goto (array2d-ref table (car new-stack) A)))
                            (loop (cons goto 
                                        (cons (apply 
                                               (vector-ref actions 
                                                           (reduce-prod-num action))
                                               args)
                                              new-stack))
                                  ip))))
                       ((accept? action)
                        (printf "accept~n")
                        (cadr stack))
                       (else 
                        (err)
                        (let ((new-stack (fix-error stack ip get-token)))
                          (if new-stack
                              (loop new-stack (get-token))
                              (void)))))))))))
      (datum->syntax-object
       runtime
       parser-code
       src))))
           