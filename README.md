PJLisp
------

Lisp interpreter I wrote for a school project.
It is based on ELisp and includes a simple mark-and-sweep garbage collector.


# Building and running #

Bison and Flex are required for building.  Also, Flex runtime library
is required (`libfl-dev` on Debian).

``` shell
make
./pjlisp --repl
```


# Examples #

## Data types ##

```
>>> 1
1
>>> "string"
"string"
>>> 'symbol
symbol
>>> (cons 1 2)
(1 . 2)
>>> '(1 2 3 4 5)
(1 2 3 4 5)
```

Dotted cons syntax is also supported.

```
>>> '(1 . 2)
(1 . 2)
>>> '(1 2 . ())
(1 2)
>>> '(1 2 . (three . nil))
(1 2 three)
```

## conses and lists ##

```
>>> (set 'x (cons "head" "tail"))
("head" . "tail")
>>> (car x)
"head"
>>> (cdr x)
"tail"
>>> (cdr '(1 2 3))
(2 3)
>>> (length '(1 2 3 4 5))
5
```

## Basic arithmetic ##

```
>>> (+ 20 30)
50
>>> (* 1 2 3 4 (+ 2 3))
120
>>> (- 10 5 -1)
6
```

## Setting and reading a global variable ##

```
>>> (set 'foo "This is the foo variable")
"This is the foo variable"
>>> foo
"This is the foo variable"
>>> bar
ERROR: (void-variable . bar)
>>> (set 'foo (+ 1 2 3))
6
```

## Local variables with `let` ##

`let`-bindings are dynamic, like in Emacs when `lexical-binding` is not used.

```
>>> (let ((x "This is x")
          (y ", and this is y"))
  (concat x y))
"This is x, and this is y"
>>> (let ((x 20)) (set 'x 40) (+ x 10))
50
```

## Lambdas ##

Lambda functions are the only way to define functions.  Unlike in
Elisp, variables and functions share the same namespace.

```
>>> (set 'fun (lambda ()  (print "Inside fun") (+ 5 10)))
lambda
>>> (fun)
"Inside fun"
15
```

Example of recursive fibonacci function:

```
>>> (set 'fib (lambda (n) 
                (if (< n 3)
                    1
                  (+ (fib (- n 1)) (fib (- n 2))))))

lambda
>>> (fib 5)
5
>>> (fib 6)
8
>>> (fib 7)
13
>>> (fib 8)
21
```

## If ##

```
>>> (if (< 20 30) (print "20 is less than 30") (print "20 >= 30"))
"20 is less than 30"
"20 is less than 30"
>>> (if (< 10 5) 'yes 'false)
false
```

## While loop ##

```
>>> (let ((x 0))
  (while (< x 5)
    (print x)
    (set 'x (+ x 1)))
  nil)
0
1
2
3
4
nil
```


