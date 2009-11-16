---
layout: default
title: kvstore REST APIs
---
# caching kvstore APIs

Version 20091112

This document specifies request and response for both the Management Console
(management channel) and the KVStore itself (data channel) when talking to
a caching kvstore (a.k.a. NorthScale Enterprise Storage).

# Assumptions

## General

JSON is the only response type, as specified under RFC4267.

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
</td><td> The authentication credentials included with this request are missing or invalid.  FIXME - talk about <i>WWW-Authenticate</i> header in the response.

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

* Cluster - A logically addressable group of pools (this may not be in _Reveal_).
* Pool - A collection of physical resources grouped together and providing
services and a management interface.  A member of a pool is a Node.
** Statistics - Pools provide an overall pool level data view of counters and
periodic metrics of the overall system.  Historic storage of statistics can be
configured and queried.
* Node - A system within a pool.  Nodes may provide Node-local representations
of a service, but are also required to provide or proxy Pool level resources.
* Bucket - A logical grouping of resources within a pool.  A bucket provides a
number of things which ease pool management and enable manageement of resources:
** Namespace - Buckets provide unconstrained, free text namespaces.
** Storage Handling Rules - Rules on how data is persisted, replicated and
otherwise handled is defined at the bucket level.
** Statistics - Buckets provide bucket level data view of counters and
periodic metrics of the overall system.  Historic storage of statistics can be
configured and queried.  These counters and metrics are specific to the bucket.

Operations for resources:



@todo finish description

# Service Groupings

## Independent of management channel and data channel
Authentication

## Management Channel
User Management
Persistent Statistics Rules
Statistics (instant)
Statistics (archived samples)


## Data Channel
###All of the "memcapable" operations

###List pool, information on the pool

For instance...

*Request*

<code class="restcalls">
 GET /pool
 Host: node.in.your.pool.com
 Authorization: Basic xxxxxxxxxxxxxxxxxxx
 Accept: application/com.northscale.store+json
 X-memcachekv-Store-Client-Specification-Version: 0.1
</code>

*Response*

<code class="json">
 HTTP/1.1 200 OK
 Content-Type: application/com.northscale.store+json
 Content-Length: nnn
 [
  {
    "name": "Default Pool",
    "id":12
    "nodes" : [
      {
        "name": "10.0.1.20",
        "uri": "/addresses/10.0.1.20",
        "ip_address": "10.0.1.20"
      }
    ]
  }
 ]
</code>

###List buckets and bucket operations

# Notes, Questions and References

## Open Questions
Both the OCCI and the Sun APIs talks about clients being required to not make
any assumptions about the URI
space at all.  This seems to make a lot of sense from an implementation
flexibility and client quality standpoint.  Should this be considered?

## References
The OCCI working group specifications http://www.occi-wg.org/ and the
Sun Cloud APIs at http://kenai.com/projects/suncloudapis/pages/Home have
influenced this document.

## Changelog
# 20091113 First publishing (matt.ingenthron@northscale.com)
# 20091115 Updated with many operations (matt.ingenthron@northscale.com)