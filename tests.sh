#!/bin/bash


lisp_test() {
    dir=$(mktemp -d --tmpdir pjlisptestXXX)
    echo "Running test \"$1\" in $dir"...

    all="$dir/all"
    body="$dir/body"
    expected="$dir/expected"
    out="$dir/out"
    cat>$all
    grep -e "^---$" -B 1000 $all | sed \$d > $body
    grep -e "^---$" -A 1000 $all | tail -n +2 > $expected

    set -e
    cat $body | ./pjlisp > $out
    diff -u $out $expected
}

should_error() {
    dir=$(mktemp -d --tmpdir pjlisptestXXX)
    echo "Running test \"$1\" in $dir"...

    body="$dir/body"
    out="$dir/out"
    cat>$body

    (cat $body | ./pjlisp) 2>/dev/null 1>$out || return 0
    echo "Expected failure, but the program didn't fail"
    echo "Output:"
    cat $out
    exit 1
}

lisp_test "Basic parsing" <<EOF
(print 123) ; comment
; comments are ignored
(print -4493)
(print 'asdf)
(print '123)
(print '"string")
(print "this is a string")
(print ())
(print '())
(print '(cons))
(print '(cons 1))
(print '(cons 1 2))
(print '(cons 1 2 three))
(print '(cons 1 2 three "four"))
---
123
-4493
asdf
123
"string"
"this is a string"
nil
nil
(cons)
(cons 1)
(cons 1 2)
(cons 1 2 three)
(cons 1 2 three "four")
EOF

should_error "Unmatched parenthesis" <<EOF
(
EOF

should_error "Non-terminated string" <<EOF
"str
EOF


should_error "Dotted cons with many sexps after cdr" <<EOF
'(1 . 1 2)
EOF

should_error "Dotted cons with empty car" <<EOF
'( . 1)
EOF

should_error "Dotted cons with empty cdr" <<EOF
'(1 . )
EOF

lisp_test "Dotted cons" <<EOF
(print '(1 . 2))
(print '(1 2 . 3))
(print '((1 2) . 3))
(print '(1 . (2 . ())))
(print '(1 . (2 3 . ())))
---
(1 . 2)
(1 2 . 3)
((1 2) . 3)
(1 2)
(1 2 3)
EOF

lisp_test "car and cdr" <<EOF
(print (car '()))
(print (car '(one)))
(print (cdr '(two)))
(print (cdr '(3 4)))
(print (car (cdr '(one two three))))
(print (cdr (cdr '(one two three))))
(print (cdr (cdr (cdr (cdr '(1 2 3 4 . 5))))))
---
nil
one
nil
(4)
two
(three)
5
EOF


lisp_test "arithmetic" <<EOF
(print (+))
(print (+ 1))
(print (+ -5 7))
(print (-))
(print (- 30))
(print (- 30 20))
(print (- 30 20 10))
(print (*))
(print (* 5))
(print (* 5 7))
---
0
1
2
0
-30
10
0
1
5
35
EOF

lisp_test "lambda" <<EOF
((lambda () (print 'Inside)))
((lambda () (print 'one) (print 'two)))
(print ((lambda () (+ 20 30))))
(print ((lambda () (+ 20 30) (+ 30 1))))
((lambda (x) (print 'inside) (print x)) (* 30 3))
((lambda (x y) (print (- x y))) 5 7)
((lambda (y x) (print (- x y))) 5 7)
---
Inside
one
two
50
31
inside
90
-2
2
EOF

should_error "lambda call with too few arguments" <<EOF
((lambda (x)))
EOF

should_error "lambda call with too many arguments" <<EOF
((lambda (x)) 1 2)
EOF

should_error "lambda with non-cons arglist" <<EOF
((lambda 1))
EOF

should_error "lambda with non-symbol argument" <<EOF
((lambda (1)))
EOF

should_error "let with non-cons arglist" <<EOF
(let 1)
EOF

should_error "let with non-cons binding" <<EOF
(let (1))
EOF

should_error "let with non-symbol variable" <<EOF
(let ((1 20)))
EOF

should_error "let with missing variable value" <<EOF
(let ((x)))
EOF

lisp_test "let"<<EOF
(let ((x 1)) (print (+ x 30)))
(let ((x (+ 1 3))) (print x) (print (+ x 30)))
(let ((x (+ 1 2)) (y (+ 3 4))) (print x) (print y))
---
31
4
34
3
7
EOF

should_error "void variable"<<EOF
unknown
EOF

lisp_test "set" <<EOF
(set 'value (+ 1 2))
(print value)
---
3
EOF

lisp_test "set inside let" <<EOF
(let ((x 1))
  (set 'x 20)
  (print x)
  (let ((x 30))
    (print x))
  (print x))
---
20
30
20
EOF

lisp_test "define function via set" <<EOF
(set 'function (lambda (x) (print (+ x 20))))
(function 10)
---
30
EOF

lisp_test "comparison" <<EOF
(print (< 20 30))
(print (< 20 10))
---
t
nil
EOF

should_error "comparison without numbers" <<EOF
(< 20 'a)
EOF

lisp_test "progn" <<EOF
(print (progn (print 1) (print 2)))
---
1
2
2
EOF

lisp_test "if" <<EOF
(if (< 20 30) (print "yes") (print "no"))
(if (< 40 30) (print "yes") (print "no1") (print "no"))
---
"yes"
"no1"
"no"
EOF

lisp_test "eq" <<EOF
(print (eq 1 1))
(print (eq 1 2))
(print (eq 'a 'a))
(print (eq 'a 'b))
(print (eq lambda lambda))
(print (eq lambda let))
(let ((c (cons 1 1))) (print (eq c c)))
(print (eq (cons 1 1) (cons 1 1)))
---
t
nil
t
nil
t
nil
t
nil
EOF

lisp_test "equal" <<EOF
(print (equal 1 1))
(print (equal 1 2))
(print (equal 'a 'a))
(print (equal 'a 'b))
(print (equal "a" "a"))
(print (equal "a" "b"))
(print (equal (cons 1 1) '(1 . 1)))
(print (equal (cons 1 2) '(1 . 1)))
---
t
nil
t
nil
t
nil
t
nil
EOF

lisp_test "length" <<EOF
(print (length nil))
(print (length '(1)))
(print (length '(1 2)))
(print (length "asd"))
---
0
1
2
3
EOF

should_error "length without a list" <<EOF
(print (length '(1 . 2)))
EOF


lisp_test "while" <<EOF
(let ((x 0))
  (while (< x 5)
    (print x)
    (set 'x (+ x 1))))
---
0
1
2
3
4
EOF


lisp_test "map"<<EOF
(print (map (lambda (x)) '(1 2 3)))
(print (map (lambda (x) (* x 2)) '(1 2 3)))
---
(nil nil nil)
(2 4 6)
EOF
