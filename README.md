PostgreSQL binding for R7RS Scheme
==================================

This is a PostgreSQL socket frontend interface library written in pure
R7RS Scheme.

NOTE: it's still working state.


Supporting implementations
--------------------------

- Sagittarius 0.5.9 or later
- Gauche 0.9.4
- Chibi Scheme 0.7

This library should be portable for R7RS if the implementation supports 
the following SRFIs;

- SRFI-106
- SRFI-60/SRFI-33


High level APIs
---------------

Library: `(postgresql)`

The library provides high level APIs to communicate PostgreSQL.


Procedure: `(postgresql-connection? obj)`

Returns `#t` if _obj_ is an PostgreSQL connection object.


Procedure: `(make-postgresql-connection host port database username password)`

`database` can be `#f`.

All arguments must be a string except `database`. Creates a PostgreSQL
connection. At this moment, the connection to the server is *not* established.


Procedure: `(postgresql-open-connection! conn)`

Establishes a connection with specified _conn_ object.


Procedure: `(postgresql-login! conn)`

Logging in to the PostgreSQL server.


Procedure: `(postgresql-terminate! conn)`

Terminates the session and disconnects connection.


Procedure: `(postgresql-query? obj)`

Returns `#t` if _obj_ is a PostgreSQL query object.


Procedure: `(postgresql-execute-sql! conn sql)`

Executes the given _sql_. If the _sql_ is a select statement then
the returning value is a PostgreSQL query object. Otherwise `#t`.
This procedure retrieves all result in one go if the _sql_ is a SELECE
statement. So it may cause memory explosion if the result set is
too big.


Procedure: `(postgresql-fetch-query! query)`

Fetch a row as a vector. If no more data are available, then returns `#f`.


Low level APIs
--------------

TBD


TODO
----

- Data conversion is not done properly
  - need some document but couldn't find it...
- Prepared statement
- Maybe buffering
  - currently it can't execute second query unless it fetches all records.