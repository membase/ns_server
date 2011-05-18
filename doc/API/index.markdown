---
layout: default
title: kvstore REST APIs
---
# caching kvstore APIs

Version 20110322

This document specifies request and response for both the Management Console
(management channel) and the cache itself (data channel) when talking to
a server managing either a cache or a membase store.


# Assumptions

## General

JSON is the only response type the system is capable of at the moment, as
specified under [RFC 4627](http://www.ietf.org/rfc/rfc4627.txt).

Authentication will be HTTP Basic.  There may be some
non-authenticated content to bootstrap browser based user interfaces that then use
HTTP Basic.

Any node of the pool will be able to handle any request.  If the node which
receives the request cannot service it directly (due to lack of access to state
or some other information) it will proxy that request to the correct node.

####Accepted Request Headers

Clients are expected to use the following standard headers when making requests
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
</td><td> No, authorization headers are not required unless the server has been "secured".
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

The Membase REST interface will return standard HTTP response codes as described
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

A typical cluster of Membase server systems have certain resources
and those resources can optionally have one or more controllers, which have
RESTful endpoints in the representation of the item one would control.

## Resources

* Pool - A collection of physical resources grouped together and providing
services.  A member of a pool is a Node.  Pools were later renamed to "clusters"
(and the previous concept of cluster changed) so this document may refer to either.
    * _Statistics_ - Pools provide an overall pool level data view of counters 
      and periodic metrics of the overall system. (note, this is missing in version 1.6)
* Node - A system within a pool.  Nodes may provide Node-local representations
of a service, but are also required to provide or proxy Pool level resources.
* Bucket - A logical grouping of resources within a pool.  A bucket provides a
number of things which ease pool management and enable management of resources:
    * _Namespace_ - Buckets provide unconstrained namespaces to users to define
      whatever bucket name makes sense to the user.  It also allows the same key
      in the same application to be available in multiple places.
    * _Statistics_ - Buckets provide bucket level data view of counters and
      periodic metrics of the overall system. These counters and metrics are
      specific to the bucket.
    * _Storage Type_ - Buckets can implement different kinds of behaviors, such
      as cache only or persisted (either synchronous or asynchronous) key-value
      stores.

## User Interface

The User Interface supplied is designed to load and run in a common
Web Browser user agent.  The UI will be composed mainly of HTML, Images, CSS and
Javascript.  It will support, as a minimum, Internet Explorer 7 & 8
and Firefox 3+.

For this, a separate UI hierarchy will be served from each node of the system (though
asking for the root "/" would likely return a redirect to the user agent.

GET https://node.in.pool.com/ui

## Bootstrapping

To behave correctly a few things must be bootstrapped.  Clients can bootstrap
themselves by looking for pools in a given system.  This is done via the initial
request/response outlined below.

The URI space, in Membase's implementation may appear to have very specific
URI and in some ways may even appear as RPC or some other architectural style
using HTTP operations and semantics.  That is only an artifact of the
URIs Membase chose.

Clients are advised to be (and Membase clients *should*
be) properly RESTful and will not expect to receive any handling instructions
resource descriptions or presume any conventions on URI structure for resources
represented.

Also note that the hierarchies shown here can allow reuse of agent handling
of representations, since they are similar for different parts of the hierarchy.

*Request*

<pre class="restcalls">
 GET /pools
 Host: node.in.your.pool.com
 Authorization: Basic xxxxxxxxxxxxxxxxxxx
 Accept: application/com.membase.store+json
 X-memcachekv-Store-Client-Specification-Version: 0.1
</pre>

*Response*

<pre class="json">
 HTTP/1.1 200 OK
 Content-Type: application/com.membase.store+json
 Content-Length: nnn

{
  "implementationVersion": "253",
  "pools" : [
    {
      "name": "Default Pool",
      "uri": "/pools/default",
    },
    {
      "name": "Membase kvcaching pool name",
      "uri": "/pools/anotherpool",
    },
    {
      "name": "A pool elsewhere",
      "uri": "https://a.node.in.another.pool.com:4321/pools/default"
    }
  ]
  "uri": "https://node.in.your.pool.com/pools",
  "specificationVersion": [
    "0.1"
   ]
}
</pre>

Only one pool per group of systems will be known and it will likely
be defaulted to a name.  POSTing back a changed pool will return a 403.

As can be seen, the "build" number of the implementation is apparent in the
implementation_version, the specifications supported are apparent in the
specification_version.  While this node can only be a member of one pool, there
is flexibility which allows for any given node to be aware of other pools.

The Client-Specification-Version is optional in the request, but advised.  It
allows for implementations to adjust to adjust representation and state
transitions to the client, if backward compatibility is desirable.

### Provisioning a Node

Before a node can be used in a cluster, a few things may need to be
configured.  Specifically, if creating a new cluster, the memory quota
per node for that cluster must be set.  Whether the node is joining an
existing cluster or starting a new cluster, it's storage path must be
configured.

Either creating a new cluster or adding a node to a cluster is
referred to as provisioning, and has several steps required.

After bootstrapping the following will need to be accomplished.

1. Configure the node's disk path.
2. Configure the cluster's memory quota.  This is optional.  It will
inherit the memory quota if the node is to be joined to a cluster and
it will default to 80% of physical memory if not specified.

The next step depends on whether a new cluster is being created or an
existing cluster will be joined.  If a new cluster is to be created,
it will need to be "secured" by providing a username and password for
the administrator.  If the node is to be joined to another cluster,
then it will need the location and credentials to the REST interface
of that cluster.


####Examples


#####Configuring the disk path for a node.

Node resources can be configured through a controller on the node.
The primary resource to be configured is the path on the node for
persisting files.  This must be configured prior to creating a new
cluster or configuring the node into an existing cluster.

*Request*

<pre class="restcalls">
POST /nodes/self/controller/settings HTTP/1.1
Host: node.in.your.cluster:8091
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
Authorization: Basic YWRtaW46YWRtaW4=
Content-Length: xx

path=/var/tmp/test
</pre>

*Response*

<pre class="json">
 HTTP/1.1 200 OK
 Content-Type: application/com.membase.store+json
 Content-Length: 0
 </pre>

<pre>curl -i -d path=/var/tmp/test http://localhost:8091/nodes/self/controller/settings</pre>

#####Configuring a cluster's memory quota.

*Request*

<pre class="restcalls">
POST /pools/default HTTP/1.1
Host: node.in.your.cluster:8091
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
Authorization: Basic YWRtaW46YWRtaW4=
Content-Length: xx

memoryQuota=400
</pre>

*Response*

<pre class="json">
 HTTP/1.1 200 OK
 Content-Type: application/com.membase.store+json
 Content-Length: 0
 </pre>

 This, for example could have been carried out with curl.

<pre>curl -i -d memoryQuota=400 http://localhost:8091/pools/default</pre>

#####Setting a node's username and password

While this can be done at any time for a cluster, it is the last step
in provisioning a node into being a new cluster.

The response will indicate the new base URI if the parameters are
accepted. Clients will want to re-bootstrap based on
this response.

*Request*

<pre class="restcalls">
POST /settings/web HTTP/1.1
Host: node.in.your.cluster:8091
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
Authorization: Basic YWRtaW46YWRtaW4=
Content-Length: xx

username=Administrator&password=letmein&port=8091
</pre>

*Response*

<pre class="json">
 HTTP/1.1 200 OK
 Content-Type: application/com.membase.store+json
 Server: Membase Server 1.6.0beta3a_124_g0fa5bd9
 Pragma: no-cache
 Date: Mon, 09 Aug 2010 18:50:00 GMT
 Content-Type: application/json
 Content-Length: 39
 Cache-Control: no-cache no-store max-age=0

{"newBaseUri":"http://localhost:8091/"}
</pre>

<pre>curl -i -d username=Administrator -d password=letmein -d port=8091 http://localhost:8091/settings/web</pre>

Note that even if it is not to be changed

###Global settings
####Setting whether statistics should be sent to the outside or not

It's a global setting for all clusters. You need to be authenticated to
change this value.

*Request*

<pre class="restcalls">
POST /settings/stats HTTP/1.1
Host: node.in.your.cluster:8091
Content-Type: application/x-www-form-urlencoded
Authorization: Basic YWRtaW46YWRtaW4=
Content-Length: 14

sendStats=true
</pre>

*Response*

200 OK
400 Bad Reqeust, The value of "sendStats" must be true or false.
401 Unauthorized

<pre>curl -i -u Administrator:letmein -d sendStats=true http://localhost:8091/settings/stats</pre>

####Getting whether statistics should be sent to the outside or not

It's a global setting for all clusters. You need to be authenticated to
read this value.

*Request*

<pre class="restcalls">
GET /settings/stats HTTP/1.1
Host: node.in.your.pool.com
Authorization: Basic YWRtaW46YWRtaW4=
Accept: */*
</pre>

*Response*

<pre class="json">
 HTTP/1.1 200 OK
 Content-Type: application/json
 Content-Length: nnn
</pre>

<pre>curl -u Administrator:letmein http://localhost:8091/settings/stats</pre>


####Setting whether auto-failover should be enabled or disabled

It's a global setting for all clusters. You need to be authenticated to
change this value.

Possible parameters are:
* enabled (true|false) (required): whether to enable or disable auto-failover
* age (integer) (required; optional when enabled=false): The number of seconds a node must be down before it is automatically failovered
* maxNodes (integer) (required; optional when enabled=false): The maximum number of nodes that can be automatically failovered

*Request*

<pre class="restcalls">
POST /settings/autoFailover HTTP/1.1
Host: node.in.your.cluster:8091
Content-Type: application/x-www-form-urlencoded
Authorization: Basic YWRtaW46YWRtaW4=
Content-Length: 14

enabled=true&age=60&maxNodes=2
</pre>

*Response*

200 OK
400 Bad Request, The value of "enabled" must be true or false.
400 Bad Request, The value of "age" must be a positive integer.
400 Bad Request, The value of "maxNodes" must be a positive integer.
401 Unauthorized
409 Conflict, Could not enable auto-failover. All nodes in the cluster need to be up and running.

<pre>curl -i -u Administrator:letmein -d enabled=true&age=60&maxNodes=2 http://localhost:8091/settings/autoFailover</pre>

####Getting information about the auto-failover settings

It's a global setting for all clusters. You need to be authenticated to
read this value.

*Request*

<pre class="restcalls">
GET /settings/autoFailover HTTP/1.1
Host: node.in.your.pool.com
Authorization: Basic YWRtaW46YWRtaW4=
Accept: */*
</pre>

*Response*

<pre class="json">
 HTTP/1.1 200 OK
 Content-Type: application/json
 Content-Length: nnn

{
    "enabled": true,
    "age": 60,
    "maxNodes": 2
}
</pre>

<pre>curl -u Administrator:letmein http://localhost:8091/settings/autoFailover</pre>

####Setting whether email notification should be enabled or disabled

It's a global setting for all clusters. You need to be authenticated to
change this value.

You will receive an email when certain events happen (currently only
events cause by auto-failover are supported).

Possible parameters are:
* enabled (true|false) (required): whether to enable or disable email notifications
* sender (string) (optional, default: membase@localhost): The sender address of the email
* recipients ([string]) (required): A comma separated list of recipients of the of the alert emails.
* emailHost (string) (optional, default: localhost): Host address of the SMTP server
* emailPort (integer) (optional, default: 25): Port of the SMTP server
* emailEncrypt (true|false) (optional, default: false): Whether you'd like to use TLS or not
* emailUser (string) (optional, default: ""): Username for the SMTP server
* emailPass (string) (optional, default: ""): Password for the SMTP server
* alerts ([string]) (optional, default: [auto_failover_node, auto_failover_maximum_reached, auto_failover_too_many_nodes_down]): Comma separated list of alerts that should cause an email to be sent. Possible values are: auto_failover_node, auto_failover_maximum_reached, auto_failover_too_many_nodes_down.

*Request*

<pre class="restcalls">
POST /settings/alerts HTTP/1.1
Host: node.in.your.cluster:8091
Content-Type: application/x-www-form-urlencoded
Authorization: Basic YWRtaW46YWRtaW4=
Content-Length: 14

enabled=true&sender=membase@localhost&recipients=admin@localhost,membi@localhost&emailHost=localhost&emailPort=25&emailEncrypt=false

</pre>

*Response*

200 OK
400 Bad Request: JSON list with errors. Possible errors are:

 * alerts contained invalid keys. Valid keys are: [list_of_keys].
 * emailEncrypt must be either true or false.
 * emailPort must be a positive integer less than 65536.
 * enabled must be either true or false.
 * recipients must be a comma separated list of valid email addresses.
 * sender must be a valid email address.

401 Unauthorized

<pre>curl -i -u Administrator:letmein -d 'enabled=true&sender=membase@localhost&recipients=admin@localhost,membi@localhost&emailHost=localhost&emailPort=25&emailEncrypt=false' http://localhost:8091/settings/alerts</pre>


###Pool Details

*Request*

<pre class="restcalls">
 GET /pools/default
 Host: node.in.your.pool.com
 Authorization: Basic xxxxxxxxxxxxxxxxxxx
 Accept: application/com.membase.store+json
 X-memcachekv-Store-Client-Specification-Version: 0.1
</pre>


*Response*

<pre class="json">
 HTTP/1.1 200 OK
 Content-Type: application/com.membase.store+json
 Content-Length: nnn
 
 {
	    "name":"default",
	    "nodes":[{
	        "hostname":"10.0.1.20",
	        "status":"healthy",
	        "uptime":"14",
	        "version":"1.6.0",
	        "os":"i386-apple-darwin9.8.0",
	        "memoryTotal":3584844000.0,
	        "memoryFree":74972000,
	        "mcdMemoryReserved":64,
	        "mcdMemoryAllocated":48,
	        "ports":{
	            "proxy":11213,
	            "direct":11212
	        },
	        "otpNode":"ns_1@node.in.your.pool.com",
	        "otpCookie":"fsekryjfoeygvgcd",
                "clusterMembership":"active"
	    }],
            "storageTotals":{
                "ram":{
                    "total":2032558091,
                    "used":1641816064
                },
                "hdd":{
                    "total":239315349504.0,
                    "used": 229742735523.0
                }
            },
	    "buckets":{
	        "uri":"/pools/default/buckets"
	    },
	    "controllers":{
	        "ejectNode":{
	            "uri":"/pools/default/controller/ejectNode"
	        },
                "addNode":{
                    "uri":"/controller/addNode"
                },
                "rebalance":{
                    "uri":"/controller/rebalance"
                },
                "failover":{
                    "uri":"/controller/failOver"
                },
                "reAddNode":{
                    "uri":"/controller/reAddNode"
                },
                "stopRebalance":{
                    "uri":"/controller/stopRebalance"
                }
	    },
            "rebalanceProgress":{
                "uri":"/pools/default/rebalanceProgress"
            },
            "balanced": true,
            "etag":"asdas123",
            "initStatus":"
	    "stats":{
	        "uri":"/pools/default/stats"
	    }
	}
 
</pre>

At the highest level, a pool describes a cluster (as mentioned above).  This
cluster exposes a number of properties which define attributes of the cluster
and "controllers" which allow users to make certain requests of the cluster.

Note that since buckets could be renamed and there is no way to determine what
the default bucket for a pool is, the system will attempt to connect non-SASL,
non-proxied to a bucket clients to a bucket named "default".  If it does not
exist, the connection will be dropped.

Clients MUST NOT rely on the node list here to create their "server list" for 
when connecting.  They MUST instead issue an HTTP get call to the bucket to 
get the node list for that specific bucket.

The controllers, all of which accept parameters as x-www-form-urlencoded, for
this list perform the following functions:

*ejectNode* - Eject a node from the cluster.  Required parameter:
"otpNode", the node to be ejected.  
*addNode* - Add a node to this cluster.  Required parameters: "hostname",
"user" (which is the admin user for the node), and "password".  
*rebalance* - Rebalance the existing cluster.  This controller
requires both
"knownNodes" and "ejectedNodes".  This allows a client to state the existing known nodes
and which nodes should be removed from the cluster in a single
operation.  To ensure no cluster state changes have occured since a
client last got a list of nodes, both the known nodes and the node to
be ejected must be supplied.  If the list does not match the set of
nodes, the request will fail with an HTTP 400 indicating a mismatch.  Note
rebalance progress is available via the rebalanceProgress uri.  
*failover* - Failover the vbuckets from a given node to the nodes which have
replicas of data for those vbuckets.  The "otpNode" parameter is required and
specifies the node to be failed over.  
*reAddNode* - The "otpNode" parameter is required and specifies the node to be
re-added.  
*stopRebalance* - Stop any rebalance operation currently running.
This takes no parameters.  

The list of nodes will list each node in the cluster.  It will,
additionally, list some attributes of the nodes.

<table>
<tr><td>memoryTotal</td><td>The total amount of memory available
to membase, allocated and free. May or may not be equal to the amount 
of memory configured in the system.</td></tr>
<tr><td>memoryFree</td><td>The amount of memory available to be
allocated.  This is equal to the memoryTotal, subtracting out all
memory allocated as reported by the host operating system.</td></tr>
<tr><td>mcdMemoryReserved</td><td>The amount of memory reserved for
use by membase across all buckets on this node.  This value does not
include some overhead for managing items in the node or handling
replication or other TAP streams.</td></tr>
<tr><td>mcdMemoryAllocated</td><td>The amount of memory actually used
by all buckets on this node.</td></tr>
</table>

####Examples


###List buckets and bucket operations

*Request*

<pre class="restcalls">
 GET /pools/default/buckets
 Host: node.in.your.pool.com
 Authorization: Basic xxxxxxxxxxxxxxxxxxx
 Accept: application/com.membase.store+json
 X-memcachekv-Store-Client-Specification-Version: 0.1
</pre>

*Response*

<pre class="json">
 HTTP/1.1 200 OK
 Content-Type: application/com.membase.store+json
 Content-Length: nnn

 [
   {
     "name" : "test-application",
     "uri" : "/pools/default/buckets/test-application",
     "streamingUri":"/pools/default/bucketsStreaming/test-applciation",
     "flushCacheUri":"/pools/default/buckets/test-application/controller/doFlush",
     "basicStats" : { "cacheSize":64,
                      "opsPerSec":0.0,
                      "evictionsPerSec":0.0,
                      "cachePercentUsed":0.0
                     },
     "nodes" : [
                 {
                   "hostname":"matt-ingenthrons-macbook-pro.home.ingenthron.org",
                   "status":"healthy",
                   "uptime":"658",
                   "version":"0.0.9_44_g4c4dfcf",
                   "os":"i386-apple-darwin9.8.0",
                   "memoryPercentUsed":0.5
                   "ports" : {
                               "proxy":11213,
                               "direct":11212
                              }
                  }
                ],
      "stats": { "uri" : "/pools/default/buckets/test-application/stats" } }
   },
   {
     "name" : "default",
     "uri" : "https://node.in.pool.com/pools/default/buckets/default",
     "streamingUri":"/pools/default/bucketsStreaming/default",
     "flushCacheUri":"/pools/default/buckets/default/controller/doFlush",
     "basicStats" : { "cacheSize":64,
                      "opsPerSec":0.0,
                      "evictionsPerSec":0.0,
                      "cachePercentUsed":0.0
                     },
     "nodes" : [
                 {
                   "hostname":"matt-ingenthrons-macbook-pro.home.ingenthron.org",
                   "status":"healthy",
                   "uptime":"658",
                   "version":"0.0.9_44_g4c4dfcf",
                   "os":"i386-apple-darwin9.8.0",
                   "memoryPercentUsed":0.5
                   "ports" : {
                               "proxy":11213,
                               "direct":11212
                              }
                  }
                ],
      "stats": { "uri" : "/pools/default/buckets/default/stats" } }
   }
 ]
 </pre>
 
Clients to the system can choose to use either the proxy path or the direct 
path.  If they use the direct path, they will not be insulated from most 
reconfiguration changes to the bucket.  This means they will need to 
either poll the bucket's URI or connect to the streamingUri to receive 
updates when the bucket configuration changes.  This happens, for instance, 
when nodes are added, removed, or may fall into an unhealthy state.

#### Named Bucket and Bucket Streaming URI

*Request*

<pre class="restcalls">
 GET /pools/default/buckets/default
 Host: node.in.your.pool.com
 Authorization: Basic xxxxxxxxxxxxxxxxxxx
 Accept: application/com.membase.store+json
 X-memcachekv-Store-Client-Specification-Version: 0.1
</pre>

*Response*

<pre class="json">
 HTTP/1.1 200 OK
 Content-Type: application/com.membase.store+json
 Content-Length: nnn

 {
   "name" : "default",
   "uri" : "https://node.in.pool.com/pools/default/buckets/default",
   "streamingUri":"/pools/default/bucketsStreaming/default",
   "flushCacheUri":"/pools/default/buckets/default/controller/doFlush",
   "basicStats" : { "cacheSize":64,
                    "opsPerSec":0.0,
                    "evictionsPerSec":0.0,
                    "cachePercentUsed":0.0
                   },
   "nodes" : [
               {                  "hostname":"matt-ingenthrons-macbook-pro.home.ingenthron.org",
                 "status":"healthy",
                 "uptime":"658",
                 "version":"0.0.9_44_g4c4dfcf",
                 "os":"i386-apple-darwin9.8.0",
                 "memoryPercentUsed":0.5
                 "ports" : {
                             "proxy":11213,
                             "direct":11212
                            }
                }
              ],
    "stats": { "uri" : "/pools/default/buckets/default/stats" } }
 }
 </pre>
 
The individual bucket request is exactly the same as what would be 
obtained from the item in the array for the entire buckets list above.

The streamingUri is exactly the same except it streams HTTP chunks using
chunked encoding.  A response of "\n\n\n\n" delimits chunks.  This will 
likely be converted to a "zero chunk" in a future release of this API, and 
thus the behavior of the streamingUri should be considered evolving.

#### Flushing a bucket

The bucket details provide a bucket URI at which a simple request can be 
made to flush the bucket.

<pre class="restcalls">
 POST /pools/default/buckets/default/controller/doFlush
 Host: node.in.your.pool.com
 Authorization: Basic xxxxxxxxxxxxxxxxxxx
 X-memcachekv-Store-Client-Specification-Version: 0.1
</pre>

Any parameters are accepted.  Since the URI was defined by the bucket
details, neither the URI nor the parameters control what is acutally done
by the service.  The simple requirement is for a POST with an appropriate
`Authorization` header, if the system is secured.

The response will be a simple `204 No Content` if the flush is successful
and a `404 Not Found` if the URI is invalid or does not correspond to a 
bucket the system is familiar with.

#### Deleting a bucket

Note that this operation is _data destructive_.  The service makes no attempt
to double check with the user.  It simply moves forward.  Clients applications
using this are advised to double check with the end user before sending such
a request.

<pre class="restcalls">
 DELETE /pools/default/buckets/default
 Host: node.in.your.pool.com
 Authorization: Basic xxxxxxxxxxxxxxxxxxx
 X-memcachekv-Store-Client-Specification-Version: 0.1
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
 GET /pools/default/stats?stat=opsbysecond&period=5m
 Host: node.in.your.pool.com
 Authorization: Basic xxxxxxxxxxxxxxxxxxx
 Accept: application/com.membase.store+json
 X-memcachekv-Store-Client-Specification-Version: 0.1
</pre>

*Response*

<pre class="json">
 HTTP/1.1 200 OK
 Content-Type: application/com.membase.store+json
 Content-Length: nnn

{
  "ops" : [ 2, 4, 5, 6, 9, 20, 30, ... ],
  "cmd_get" : [ 2, 4, 5, 6, 9, 20, 30, ... ],
  "get_misses" : [ 2, 4, 5, 6, 9, 20, 30, .. ],
  "get_hits" : [ 2, 4, 5, 6, 9, 20, 30, .. ],
  "cmd_set" : [ 2, 4, 5, 6, 9, 20, 30, .. ],
  "evictions" : [ 2, 4, 5, 6, 9, 20, 30, .. ],
  "misses" : [ 2, 4, 5, 6, 9, 20, 30, .. ],
  "updates" : [ 2, 4, 5, 6, 9, 20, 30, .. ],
  "bytes_read" : [ 2, 4, 5, 6, 9, 20, 30, .. ],
  "bytes_written" : [ 2, 4, 5, 6, 9, 20, 30, .. ],
  "hit_ratio" : [ 2, 4, 5, 6, 9, 20, 30, .. ],
  "curr_items" : [ 2, 4, 5, 6, 9, 20, 30, .. ]
}
</pre>

Note that there are situations where one may need the total number of
calculations.  In that case, simply add the values needed on the client.

These map to memcached stats as follows:
ops SUM(cmd_get, cmd_set,
			incr_misses, incr_hits,
			decr_misses, decr_hits,
			cas_misses, cas_hits, cas_badval,
			delete_misses, delete_hits,
			cmd_flush)
cmd_get (cmd_get)
get_misses (get_misses)
get_hits (get_hits)
cmd_set (cmd_set)
evictions (evictions)
replacements (if available in time)
misses SUM(get_misses, delete_misses, incr_misses, decr_misses,
			cas_misses)
updates SUM(cmd_set, incr_hits, decr_hits, cas_hits)
bytes_read (bytes_read)
bytes_written (bytes_written)
hit_ratio (get_hits / cmd_get)
curr_items (curr_items)

--------------

There are both bucket and pool level statistics on hot keys.  The response
resource is the same to aid code reuse.

*Request*

<pre class="restcalls">
 GET /pools/default/stats?stat=hot_keys&number=10
 Host: node.in.your.pool.com
 Authorization: Basic xxxxxxxxxxxxxxxxxxx
 Accept: application/com.membase.store+json
 X-memcachekv-Store-Client-Specification-Version: 0.1
</pre>

_Note:_ the GET above could have been "/pools/default/buckets/Exerciser Application"
to generate the same kind of response.

*Response*

<pre class="json">
 HTTP/1.1 200 OK
 Content-Type: application/com.membase.store+json
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

A new bucket may be created with a POST command to the URI to the buckets defined URI for
the pool.  This can be used to create either a membase or a memcache
type bucket.

The bucket name cannot have a leading underscore.

When creating a bucket, an authType parameter must be specified.  If
the authType is "none" then a proxyPort number MUST be specified.  If
the authType is "sasl" then a "saslPassword" parameter MAY be
optionally specified.  In release 1.6, any SASL auth based access
must go through the proxy which is fixed to port 11211.

The ramQuotaMB attribute allows the user to specify how much memory
(in megabytes) will be allocated on each node for the bucket.  In the
case of memcache buckets, going beyond the ramQuotaMB will cause an
item to be evicted on a mostly-LRU basis.  The type of item evicted
may not be the exact LRU due to object size, whether or not it is
currently being referenced or other situations.

In the case of membase buckets, the system may return temporary
failures if the ramQuotaMB is reached.  The system will try to keep
25% of the available ramQuotaMB free for new items by *ejecting*
old items from occupying memory.  In the event these items are later
requested, they will be retrieved from disk.

######Creating a memcache Bucket

*Request*

<pre class="restcalls">
POST /pools/default/buckets HTTP/1.1
Host: node.in.your.cluster:8091
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
Authorization: Basic YWRtaW46YWRtaW4=
Content-Length: xx

name=newcachebucket&ramQuotaMB=128&authType=none&proxyPort=11216&bucketType=memcached
</pre>

*Response*

response 202: bucket will be created asynchronously with the location
header returned.  No URI to check for the completion task is
available, but most bucket creations complete within a few seconds.


*Example*
`curl -i -d name=newcachebucket -d ramQuotaMB=128 -d authType=none -d proxyPort=11216 -d bucketType=memcached http://localhost:8080/pools/default/buckets
`
HTTP/1.1 201 Created
Server: Membase Server 1.6.
Pragma: no-cache
Location: /pools/default/buckets/newcachebucket
Date: Wed, 29 Sep 2010 18:52:39 GMT
Content-Length: 0
Cache-Control: no-cache no-store max-age=0



######Creating a Membase Bucket

In addition to the aforementioned parameters, a replicaNumber parame

*Request*

<pre class="restcalls">
POST /pools/default/buckets HTTP/1.1
Host: node.in.your.cluster:8080
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
Authorization: Basic YWRtaW46YWRtaW4=
Content-Length: xx

name=newbucket&ramQuotaMB=20&authType=none&replicaNumber=2&proxyPort=11215
</pre>

*Response*

Response 202: bucket will be created.

*Example*
<pre>curl -i -u Administrator:letmein -d name=newbucket -d ramQuotaMB=20 -d authType=none -d replicaNumber=2 -d proxyPort=11215 http://localhost:8080/pools/default/buckets</pre>


#####Getting a Bucket

*Request*

<pre class="restcalls">
GET /pools/default/buckets/Another bucket
</pre>


<pre class="restcalls">
HTTP/1.1 200 OK
Content-Type: application/com.membase.store+json
Content-Length: nnn

{
   "name" : "Another bucket"
   "bucketRules" : {
     "cacheRange" :
       {
         "min" : 1,
         "max" : 599
       },
     "replicationFactor" : 2
   }
   "nodes" : [
              {
                "hostname" : "10.0.1.20",
                "uri" : "/addresses/10.0.1.20",
                "status" : "healthy",
                "ports" : {
                  "routing" : 11211,
                  "kvcache" : 11311
                }
              },
              {
                "hostname" : "10.0.1.21",
                "uri" : "/addresses/10.0.1.21",
                "status" : "healthy",
                "ports" : {
                  "routing" : 11211,
                  "kvcache" : 11311
                }
              }
   ]
}
</pre>


Clients MUST use the nodes list from the bucket, not the pool to indicate which
are the appropriate nodes to connect to.

###Modifying Bucket Properties

Buckets may be modified by POSTing the same kind of parameters used to
create the bucket to the bucket's URI.  Since an omitted parameter can
be equivalent to not setting it in some cases, it is recommended that
clients get existing parameters, make modifications where necessary,
and then POST to the URI.

The name of a bucket cannot be changed.

####Example: Increasing the Memory Quota for a Bucket

Increasing a bucket's ramQuotaMB from the current level.  Note, the
system will not let you decrease the ramQuotaMB for a membase bucket
type and memcached bucket types will be flushed when the ramQuotaMB is
changed.

*Note*: as of 1.6.0, there are some known issues with changing the
 ramQuotaMB for memcached bucket types.

*Request*


For example, with curl:
`$ curl -i -u Administrator:QuotaMB=25 -d authType=none -d proxyPort=11215 http://localhost:8080/pools/default/buckets/newbucket`

*Response*

The response will be a 202, indicating the quota will be changed
asynchronously throughout the servers in the cluster.

`HTTP/1.1 202 OK
Server: Membase Server 1.6.0
Pragma: no-cache
Date: Wed, 29 Sep 2010 20:01:37 GMT
Content-Length: 0
Cache-Control: no-cache no-store max-age=0`


####Example: Changing Bucket Autentication

Changing a bucket from port based authentication to SASL
authentication can be done with:

$ curl -u Administrator:letmein -i -d ramQuotaMB=130 -d authType=sasl -d saslPassword=letmein  http://localhost:8080/pools/default/buckets/acache


#### Cluster and Pool Operations

Creating a new pool is not currently supported.

A new pool may be supported in future releases.  At that time a pool can be
created by posting to the /pools URI.

*Request*

<pre class="restcalls">
POST /pools/mynewpool

 name=mynewpool
</pre>

*Response*


response 201: pool was created and valid URIs for referencing it returned
 - or -
response 403: user is not authorized (or no users are authorized because it
is administratively disabled to all users)

At release of 1.0, this will always return 405 Method Not Allowed.


#### Joining a Cluster

Clusters (a.k.a. pools) cannot be merged if they are made of multiple nodes.  However, a single node
can be asked to join a cluster.  It will need several parameters to be able to negotiate a join to the
cluster.

*Request*

<pre class="restcalls">
 POST /node/controller/doJoinCluster
 Host: target.node.to.do.join.from:8091
 Authorization: Basic xxxxxxxxxxxx
 Accept: */*
 Content-Length: xxxxxxxxxx
 Content-Type: application/x-www-form-urlencoded

 clusterMemberHostIp=192%2E168%2E0%2E1&clusterMemberPort=8091&user=admin&password=admin123
</pre>

The following are required:
* clusterMemberNodeHostIp - Hostname or IP address to a member of the cluster the node receiving this POST will be joining
* clusterMemberPort - The port number for the RESTful interface to the system

If the server has been "secured" via the console, the following are also required
* user - The user which has administrative privileges to access the server
* password - The password for the administrative user specified in the user portion of the form

*Response*
200 OK with Location header pointing to pool details of pool just joined - successful join
400 Bad Request - missing parameters, etc.
401 Unauthorized - credentials required, but not supplied
403 Forbidden bad credentials - invalid credentials

For example to make this request from curl:
`curl --data-urlencode clusterMemberHostIp=192.168.0.1 --data-urlencode clusterMemberPort=8091 --data-urlencode user=admin --data-urlencode password=admin123 http://localhost:8091/node/controller/doJoinCluster`

#### Ejecting a node from a cluster

In situations where a node is down either temporarily or permanently,
we may need to eject it from the cluster.  It may also be important
to eject a node from another node participating in the same cluster.

* Request *

<pre class="restcalls">
POST /controller/ejectNode
Host: altnernate.node.in.cluster:8091
Authorization: Basic xxxxxxxxxxxx
Accept: */*
Content-Length: xxxxxxxxxx
Content-Type: application/x-www-form-urlencoded

otpNode=ns_1@192%2E168%2E0%2E1
</pre>

* Response *
200 OK, node ejected
401 Credentials were not supplied and are required
403 Credentials were supplied and are incorrect
400 Error, the node to be ejected doesn't exist

For example, to make this request from curl:
`$ curl --user admin -i --data otpNode=ns_1@192.168.0.107 http://192.168.0.106:8091/controller/ejectNode`


#### System Logs

System modules log various messages, which are available via this interface.  These log messages are
optionally categorized by the module.  Both a generic list of recent log entries and recent log entries
for a particular category are available.  A GET without specifying a category returns all categories.

<pre class="restcalls">
GET /pools/default/logs?cat=crit
Host: node.in.your.pool.com
Authorization: Basic xxxxxxxxxxxxxxxxxxx
Accept: application/com.membase.store+json
X-memcachekv-Store-Client-Specification-Version: 0.1
</pre>

response 201: bucket was created and valid URIs returned

<pre class="restcalls">
HTTP/1.1 200 OK
Content-Type: application/com.membase.store+json
Content-Length: nnn

[{"cat":"info", "date": "", "code": "302", "message": "Some information for you."},
 {"cat":"warn", "date": "", "code": "502", "message": "Something needs attention."}]
</pre>

Types may be "info" "crit" or "warn".  Accessing logs requires administrator credentials if
the system is secured.

#### Client logging interface

* Request *

<pre class="restcalls">
POST /logClientError
Host: node.in.your.pool.com
Authorization: Basic xxxxxxxxxxxxxxxxxxx
Accept: application/com.membase.store+json
X-memcachekv-Store-Client-Specification-Version: 0.1
</pre>

* Response *

200 - OK

Clients may wish to add entries to the service's central logger.  These entries would
typically be responses to exceptional like difficulty handling a server response.
For instance, the  Web UI uses this functionality to log client error conditions for
later diagnosis.

# Notes, Questions and References

## Open Questions
* Where are users managed?
* How is "preallocate" for the bucket expressed?

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
* 20091117 Updated after defending REST and HTTP in discussion with Steve
  (matt.ingenthron@northscale.com)
* 20091118 Fleshed out details on the requests and responses
  (matt.ingenthron@northscale.com)
* 20091119 Added more info on stats. (matt.ingenthron@northscale.com)
* 20091202 Made pools and nodes plural (as they should have been); added port
  information for nodes. (matt.ingenthron@northscale.com)
* 20091207 Removed default bucket, removed ID/GUIDs from buckets/pools, changed
  bucket rules to be single value cache range rather than persist range.  Added
  bucket renaming. (matt.ingenthron@northscale.com)
* 20091208 Added bucket level preferred port configuration to RESTful 
  interface. (matt.ingenthron@northscale.com)
* 20091210 Moved to camelCase for JSON object names.  Added restrictions on
  pool and bucket names.  (matt.ingenthron@northscale.com)
* 20101207 Changed some paths to plural from singlular.  Reflected node tracking
  changes moving to buckets.
* 20100112 Removed per-node requests
* 20100120 Documented bucket delete
* 20100120 Added small to-do list for implementation
* 20100126 Fixed buckets definition from pool level and pool wide array level.
* 20100128 Removed todo list, it's duplicating Menelaus's TODO.
* 20100128 Updated add bucket definition
* 20100129 Updated create bucket documentation
* 20100209 Updated pool details, many fixes, adding cache reserved and allocated
* 20100218 Added documentation on removing a node
* 20100224 Documented client logging interface and cleaned up some
  legacy things
* 20100803 Various updates for 1.6, mostly to pool resource
* 20100809 Added section on provisioning and provisioning calls
* 20101029 Updated bucket creation and modification to reflect
  memcached/membase buckets
* 20110322 Added info about sendStats setting
