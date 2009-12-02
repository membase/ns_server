---
layout: default
title: kvstore REST APIs
---
# caching kvstore APIs

Version 20091202

This document specifies request and response for both the Management Console
(management channel) and the KVStore itself (data channel) when talking to
a caching kvstore (a.k.a. NorthScale Enterprise Storage).

Note, *Reveal* referred to in this document is code for 1.0.

# Assumptions

## General

JSON is the only response type the system is capable of at the moment, as
specified under [RFC 4627](http://www.ietf.org/rfc/rfc4627.txt).

Authentication will be HTTP Basic, generally over SSL/TLS.  There may be some
non-authenticated content to bootstrap browser based user interfaces that then use
HTTP Basic with SSL/TLS.

Any node of the pool will be able to handle any request.  If the node which
receives the request cannot service it directly (due to lack of access to state
or some other information) it will proxy that request to the correct node.

####Accepted Request Headers

Clients are expected to usethe following standard headers when making requests
to any URI.

<table border="1" width="100%">
<tr><th> Header
</th><th> Supported Values
</th><th> Description of Use
</th><th> Required
</th></tr>
<tr><td> Accept
</td><td> Comma-delimited list of media types or media type patterns.
</td><td> Indicates to the server what media type(s) this client is prepared to accept.
</td><td> Recommended, on requests that will produce a response message body.
</td></tr>
<tr><td> Authorization
</td><td> &quot;Basic &quot; plus username and password (per RFC 2617).
</td><td> Identifies the authorized user making this request.
</td><td> Yes, on all requests.  The only exception is the few cases where
</td></tr>
<tr><td> Content-Length
</td><td> Length (in bytes) of the request message body.
</td><td> Describes the size of the message body.
</td><td> Yes, on requests that contain a message body.(1)
</td></tr>
<tr><td> Content-Type
</td><td> Media type describing the request message body.
</td><td> Describes the representation and syntax of the request message body.
</td><td> Yes, on requests that contain a message body.
</td></tr>
<tr><td> Host
</td><td> Identifies the origin host receiving the message.
</td><td> Required to allow support of multiple origin hosts at a single IP address.
</td><td> All requests.  Note that since a single Space may spread its URIs across multiple hosts, this may need to be re-set for each request.
</td></tr>
<tr><td> X-YYYYY-Client-Specification-Version
</td><td> String containing a specification version number.
</td><td> Declares the specification version of the YYYYY API that this client was programmed against.
</td><td> No (current version is assumed if this header is not present).
</td></tr>
</table>

####Standard HTTP Status Codes

Enterprise Storage APIs will return standard HTTP response codes as described
in the following table, under the conditions listed in the description.

<div style="overflow-x: auto;"><div style="margin: 0px 2px 0px 2px;">
<table border="1" width="100%"><tr><th> HTTP Status
</th><th> Description
</th></tr>
<tr><td> 200 OK
</td><td> The request was successfully completed.  If this request created a new resource that is addressable with a URI, and a response body is returned containing a representation of the new resource, a 200 status will be returned with a <i>Location</i> header containing the canonical URI for the newly created resource.
</td></tr>
<tr><td> 201 Created
</td><td> A request that created a new resource was completed, and no response body containing a representation of the new resource is being returned.  A <i>Location</i> header containing the canonical URI for the newly created resource should also be returned.
</td></tr>
<tr><td> 202 Accepted
</td><td> The request has been accepted for processing, but the processing has not been completed.  Per the HTTP/1.1 specification, the returned entity (if any) <b>SHOULD</b> include an indication of the request's current status, and either a pointer to a status monitor or some estimate of when the user can expect the request to be fulfilled.
</td></tr>
<tr><td> 204 No Content
</td><td> The server fulfilled the request, but does not need to return a response message body.
</td></tr>
<tr><td> 400 Bad Request
</td><td> The request could not be processed because it contains missing or invalid information (such as validation error on an input field, a missing required value, and so on).
</td></tr>
<tr><td> 401 Unauthorized
</td><td> The authentication credentials included with this request are missing or invalid.
</td></tr>
<tr><td> 403 Forbidden
</td><td> The server recognized your credentials, but you do not possess authorization to perform this request.
</td></tr>
<tr><td> 404 Not Found
</td><td> The request specified a URI of a resource that does not exist.
</td></tr>
<tr><td> 405 Method Not Allowed
</td><td> The HTTP verb specified in the request (DELETE, GET, HEAD, POST, PUT) is not supported for this request URI.
</td></tr>
<tr><td> 406 Not Acceptable
</td><td> The resource identified by this request is not capable of generating a representation corresponding to one of the media types in the <i>Accept</i> header of the request.
</td></tr>
<tr><td> 409 Conflict
</td><td> A creation or update request could not be completed, because it would cause a conflict in the current state of the resources supported by the server (for example, an attempt to create a new resource with a unique identifier already assigned to some existing resource).
</td></tr>
<tr><td> 500 Internal Server Error
</td><td> The server encountered an unexpected condition which prevented it from fulfilling the request.
</td></tr>
<tr><td> 501 Not Implemented
</td><td> The server does not (currently) support the functionality required to fulfill the request.
</td></tr>
<tr><td> 503 Service Unavailable
</td><td> The server is currently unable to handle the request due to temporary overloading or maintenance of the server.
</td></tr>
</table>
</div></div>

# Resources and Operations

A typical cluster of NorthScale Enterprise Storage systems has certain resources
and those resources can optionally have one or more controllers, which have
RESTful endpoints in the representation of the item one would control.

## Resources

* Cluster - A logically addressable group of pools (this is not in Reveal, and
is not discussed any further in this document).
* Pool - A collection of physical resources grouped together and providing
services and a management interface.  A member of a pool is a Node.
** Statistics - Pools provide an overall pool level data view of counters and
periodic metrics of the overall system.  Historic storage of statistics can be
configured and queried.
* Node - A system within a pool.  Nodes may provide Node-local representations
of a service, but are also required to provide or proxy Pool level resources.
* Bucket - A logical grouping of resources within a pool.  A bucket provides a
number of things which ease pool management and enable management of resources:
  >_Namespace_ - Buckets provide unconstrained namespaces to users to define
  > whatever bucket name makes sense to the user.  It also allows the same key
  > in the same application to be available in multiple places.

  >_Storage Handling Rules_ - Rules on how data is persisted, replicated and
  > otherwise handled is defined at the bucket level.

  >_Statistics_ - Buckets provide bucket level data view of counters and
  > periodic metrics of the overall system.  Historic storage of statistics
  > can be configured and queried.  These counters and metrics are specific to
  > the bucket.

## User Interface

The User Interface shipped by NorthScale is designed to load and run in a common
Web Browser user agent.  The UI will be composed mainly of HTML, Images, CSS and
Javascript.  It will support, as a minimum, Internet Explorer 6 / 7 / 8
and Firefox 3+.

For this, a separate UI heirarcy will be served from each node of the system (though
asking for the root "/" would likely return a redirect to the user agent.

GET https://node.in.pool.com/ui

## Bootstrapping

To behave correctly a few things must be bootstrapped.  Clients can bootstrap
themselves by looking for pools in a given system.  This is done via the initial
request/response outlined below.

The URI space, in NorthScale's implementation may appear to have very specific
URI and in some ways may even appear as RPC or some other architectural style
using HTTP operations and semantics.  That is only an artifact of the
URIs NorthScale chose.

Clients are advised to be (and NorthScale clients will
be) properly RESTful and will not expect to receive any handling instructions
resource descriptions or presume any conventions on URI structure for resources
represented.

Also note that the heirarchies shown here can allow reuse of agent handling
of representations, since they are similar for different parts of the heirarchy.

*Request*

<pre class="restcalls">
 GET /pool
 Host: node.in.your.pool.com
 Authorization: Basic xxxxxxxxxxxxxxxxxxx
 Accept: application/com.northscale.store+json
 X-memcachekv-Store-Client-Specification-Version: 0.1
</pre>

*Response*

<pre class="json">
 HTTP/1.1 200 OK
 Content-Type: application/com.northscale.store+json
 Content-Length: nnn
{
  "implementation_version": "253",
  "pools" : [
    {
      "name": "Default Pool",
      "uri": "/pool/default",
    },
    {
      "name": "NorthScale kvcaching pool name",
      "uri": "/pool/anotherpool",
    },
    {
      "name": "A pool elsewhere",
      "uri": "https://a.node.in.another.pool.com:4321/pool/default"
    }
  ]
  "uri": "https://node.in.your.pool.com/pool",
  "specification_version": [
    "0.1"
   ]
}
</pre>

At *Reveal*, only one pool per group of systems will be known and it will likely
be defaulted to a name.  POSTing back a changed pool will return a 403.

As can be seen, the "build" number of the implementation is apparent in the
implementation_version, the specifications supported are apparent in the
specficiation_version.  While this node can only be a member of one pool, there
is flexibility which allows for any given node to be aware of other pools.

The Client-Specificaion-Version is optional in the request, but advised.  It
allows for implementations to adjust to adjust representation and state
transitions to the client, if backward compatibility is desirable.

###Pool Details

*Request*

<pre class="restcalls">
 GET /pool/Default Pool
 Host: node.in.your.pool.com
 Authorization: Basic xxxxxxxxxxxxxxxxxxx
 Accept: application/com.northscale.store+json
 X-memcachekv-Store-Client-Specification-Version: 0.1
</pre>

Note, this could also have been a GET operation to the pool's GUID instead of
the human readable pool name.


*Response*

<pre class="json">
 HTTP/1.1 200 OK
 Content-Type: application/com.northscale.store+json
 Content-Length: nnn
 {
   "name" : "Default Pool",
   "id" : 1,
   "state": {
     "current" : "transitioning",
     "uri" : "/pool/Default Pool/state"
   }
   "node" : [
     {
       "name" : "10.0.1.20",
       "uri" : "/addresses/10.0.1.20",
       "ip_address" : "10.0.1.20",
       "status" : "healthy",
       "ports" : {
         "routing" : 11211,
         "caching" : 11311,
         "kvstore" : 11411
       }
     },
     {
       "name" : "10.0.1.21",
       "uri" : "/addresses/10.0.1.21",
       "ip_address" : "10.0.1.20",
       "status" : "healthy",
       "ports" : {
         "routing" : 11211,
         "caching" : 11311,
         "kvstore" : 11411
       }
     }
   ]
   "bucket" : [
     {
       "name" : "yourbucket",
       "guid" : "lksjdflskjdlfj",
       "uri" : "https://node.in.pool.com/pool/Default Pool/bucket/yourbucket"
     },
     {
       "name" : "yourotherbucket",
       "guid" : "lksjdflskjdlfj",
       "uri" : "https://node.in.pool.com/pool/Default Pool/bucket/yourotherbucket"
     }
   ],
   "default-bucket" : "yourbucket",
   "controller" : {
      "backup" : {
        "uri" : "https://node.in.pool.com/startbackup"
      },
      "scrub" : {
        "uri" : "ops/start-scrub"
      }
   },
   "stats" : {
     "uri" : "http://node.in.pool.com/Default Pool/stats"
    }
 }
</pre>

The pool state could be "stable" "unstable" "transitioning" or other values
which allows the admin UI or clients to see current state and get further
details if there are some about the updated state.  The URI may be optional
and will likely be omitted in the "stable" case.

####Node Details

*Request*

<pre class="restcalls">
 GET https://first_node.in.pool.com:80/pool/Default Pool/node/first_node/
 Host: node.in.your.pool.com
 Authorization: Basic xxxxxxxxxxxxxxxxxxx
 Accept: application/com.northscale.store+json
 X-memcachekv-Store-Client-Specification-Version: 0.1
</pre>


In Javascript, this would lead to being able to, for instance, be able to address
a URI on a node directly.  An example of why one may want to do this is either
for system internal management routines or per-node operations which may make
sense, like a backup or asking a node to join a pool.

*Response*

<pre>
{
  "name" : "first_node",
  "threads" : 8,
  "cache" : "3gb",
  "status: "healthy",
  "ports" : {
    "routing" : 11211,
    "caching" : 11311,
    "kvstore" : 11411
  }
  "os" : "none",
  "version" : "123",
  "uptime" : 1231293
}
</pre>


###List buckets and bucket operations

*Request*

<pre class="restcalls">
 GET /pool/Default Pool/bucket
 Host: node.in.your.pool.com
 Authorization: Basic xxxxxxxxxxxxxxxxxxx
 Accept: application/com.northscale.store+json
 X-memcachekv-Store-Client-Specification-Version: 0.1
</pre>

*Response*

<pre class="json">
 HTTP/1.1 200 OK
 Content-Type: application/com.northscale.store+json
 Content-Length: nnn
 "buckets" : [
   {
     "name" : "yourbucket",
     "guid" : "lksjdflskjdlfj",
     "uri" : "https://node.in.pool.com/pool/Default Pool/bucket/yourbucket"
   }
 ]
</pre>

###Statistics

Statistics can be gathered via the REST interface at either the pool or the
bucket level.  The JSON response will be similar at both levels, allowing for
some polymorphic-like reuse by components using those objects.

Statistics fall into a few different categories.
* Real-time statistics for the the bucket/pool in question.  This is a Comet/Bayeaux
long-poll value.
* Historic statistics with varying periodic resolutions.  The system will store
calculated data at 5 minute intervals, but will support 5 minute ("5m"), 30
minute ("30m", 1 hour ("1h") and 24 hour ("24h") resolutions.
* Top key values.  This is a complete list of the _hot keys_ for either the
bucket or pool.

*Request*

<pre class="restcalls">
 GET /pool/Default Pool/stats?stat=opsbysecond&period=5m
 Host: node.in.your.pool.com
 Authorization: Basic xxxxxxxxxxxxxxxxxxx
 Accept: application/com.northscale.store+json
 X-memcachekv-Store-Client-Specification-Version: 0.1
</pre>

*Response*

<pre class="json">
 HTTP/1.1 200 OK
 Content-Type: application/com.northscale.store+json
 Content-Length: nnn

{
  "getsbysecond" : [ 2, 4, 5, 6, 9, 20, 30, ... ],
  "setsbysecond" : [ 2, 4, 5, 6, 9, 20, 30, ... ],
  "missesbysecond" : [ 2, 4, 5, 6, 9, 20, 30, .. ]
}
</pre>

Note that there are situations where one may need the total number of
calculations.  In that case, simply add the values needed on the client.

--------------

There are both bucket and pool level statistics on hot keys.  The response
resource is the same to aid code reuse.

*Request*

<pre class="restcalls">
 GET /pool/Default Pool/stats?stat=hot_keys&number=10
 Host: node.in.your.pool.com
 Authorization: Basic xxxxxxxxxxxxxxxxxxx
 Accept: application/com.northscale.store+json
 X-memcachekv-Store-Client-Specification-Version: 0.1
</pre>

_Note:_ the GET above could have been "/pool/Default Pool/bucket/Exerciser Application"
to generate the same kind of response.

*Response*

<pre class="json">
 HTTP/1.1 200 OK
 Content-Type: application/com.northscale.store+json
 Content-Length: nnn

{
  "hot_keys : [
    { "gets" : 10000 , "name" : "user:image:value", "misses" : 100, "type" : "Persistent", "bucket" : "Exerciser Application" },
    { "gets" : 10000, "name" : "user:image:value2", "misses" : 100, "type" : "Cache", "bucket" : "Exerciser Application"},
    { "gets" : 10000, "name" : "user:image:value3", "misses" : 100, "type" : "Persistent", "bucket" : "Exerciser Application"},
    { "gets" : 10000, "name" : "user:image:value4", "misses" : 100, "type" : "Cache", "bucket" : "Exerciser Application"}
  ]
</pre>


####Bucket resources

*Request*

PUT /pool/My New Pool/bucket/New bucket
{
   "name" : "New bucket"
}

*Response*

response 201: bucket was created and valid URIs returned


POST /pool/My New Pool/bucket/Another bucket
{
   "name" : "Another bucket"
   "bucketrules" : {
     "persist-range" : [
       {
         "min" : 0,
         "max" : 0
       },
       {
         "min" : 600
       }
     ]
     "replication-factor" : 2
   }
}

The bucket rules above show that for the bucket "Another bucket" the bucketrules
are to persist for two expiration value ranges.  One is from 0 to 0, meaning
all items which should not expire will persist.  The application developer is
therefore responsible for cleaning up any of these items.  The second range is
from 600 seconds (10 minutes) with no maxiumum.  This means any item with an
expiration equal to or greater than 10 minutes will be persisted.

Note that replication factor (a.k.a. in memory replication across cache nodes)
may not be supported at 1.0.

#### Pool Operations

*Request*

POST /pool/My New Pool
{
   "name" : "My New Pool"
}

*Response*


response 201: pool was created and valid URIs for referencing it returned
 - or -
response 403: user is not authorized (or no users are authorized because it
is administratively disabled to all users)

At release of 1.0, this will always return a 403.


# Notes, Questions and References

## Open Questions
* Currently, users cannot have multiple pools with the same name managed by the
  same infrastructure.  They also cannot have multiple buckets with the same
  names.  This could be an issue in the future.  A globally unique id for either
  the pool or the bucket could be introduced.  At the moment, it's probably
  better to just "punt" and recognize that we may some day we may need to allow
  for merging of pools and buckets, resolving name conflicts.
* Are ports configurable?  Is this at the node level or the pool level?
* Where are users managed?

## References
The [OCCI working group specifications](http://www.occi-wg.org/) and the
[Sun Cloud APIs](http://kenai.com/projects/suncloudapis/pages/Home) have
influenced this document.  To ensure it is properly RESTful, Roy Fielding's
publications and particularly
[this blog](http://roy.gbiv.com/untangled/2008/rest-apis-must-be-hypertext-driven)
and [this blog](http://roy.gbiv.com/untangled/2009/it-is-okay-to-use-post)
have been referenced.

## Changelog
* 20091113 First publishing (matt.ingenthron@northscale.com)
* 20091115 Updated with some operations (matt.ingenthron@northscale.com)
* 20091117 Updated after defending REST and HTTP in discussion with Steve (matt.ingenthron@northscale.com)
* 20091118 Fleshed out details on the requests and responses (matt.ingenthron@northscale.com)
* 20091119 More info on stats (matt.ingenthron@northscale.com)
* 20091202 Made pools and nodes plural (as they should have been), added port
  information for nodes