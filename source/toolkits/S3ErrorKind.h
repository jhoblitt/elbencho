// SPDX-FileCopyrightText: 2020-2026 Sven Breuner and elbencho contributors
// SPDX-License-Identifier: GPL-3.0-only

#ifndef TOOLKITS_S3ERRORKIND_H_
#define TOOLKITS_S3ERRORKIND_H_

#ifdef S3_SUPPORT

#include <cstdlib>
#include <string>

#include <aws/core/client/AWSError.h>
#include <aws/core/client/CoreErrors.h>

#include "ErrorCounts.h"
#include "toolkits/StringTk.h"

/**
 * Map a failed S3 outcome to an error kind string for ErrorCounts.
 *
 * A received http status is the answer of the server and thus always wins ("http_<code>"). Without
 * a status, the failure happened on the client side: the AWS SDK's curl http client reports the
 * curl error code in the message as "curlCode: <n>, ..." and its CRT client reports the CRT error
 * name in the message, e.g. "(aws-c-io: AWS_IO_SOCKET_TIMEOUT)". The CRT names are matched on a
 * best-effort basis. A connection failure ("conn_fail") means no connection could be established;
 * a connection reset ("conn_reset") means the connection broke before or during the response. An
 * unmapped curl error code is reported as "curl_<n>" instead of falling back to "other".
 *
 * Templated so it works both for a specific client's error type (e.g. S3ErrorType, which mirrors
 * Aws::Client::CoreErrors, see S3Errors.h "From Core") and for the
 * Aws::Client::AWSError<Aws::Client::CoreErrors> that the retry strategy sees.
 */
template <typename AWSErrorT>
std::string s3ErrorToKindStr(const AWSErrorT& error)
{
    const int responseCode = (int)error.GetResponseCode();

    if(responseCode >= 300)
        return ERRORCOUNTS_KIND_HTTP_PREFIX + std::to_string(responseCode);

    if( (int)error.GetErrorType() == (int)Aws::Client::CoreErrors::REQUEST_TIMEOUT)
        return ERRORCOUNTS_KIND_TIMEOUT; // (CRT client maps its request timeout to this type)

    const std::string message(error.GetMessage().c_str() );
    const std::string curlPrefix = "curlCode: ";

    if(StringTk::checkForPrefix(message, curlPrefix) )
    {
        const long curlCode = strtol(message.c_str() + curlPrefix.length(), NULL, 10);

        switch(curlCode)
        {
            case 28: // CURLE_OPERATION_TIMEDOUT (also for connect timeouts)
                return ERRORCOUNTS_KIND_TIMEOUT;
            case 5: // CURLE_COULDNT_RESOLVE_PROXY
            case 6: // CURLE_COULDNT_RESOLVE_HOST
            case 7: // CURLE_COULDNT_CONNECT
            case 35: // CURLE_SSL_CONNECT_ERROR
                return ERRORCOUNTS_KIND_CONNFAIL;
            case 18: // CURLE_PARTIAL_FILE
            case 52: // CURLE_GOT_NOTHING
            case 55: // CURLE_SEND_ERROR
            case 56: // CURLE_RECV_ERROR
                return ERRORCOUNTS_KIND_CONNRESET;
            default:
                return ERRORCOUNTS_KIND_CURL_PREFIX + std::to_string(curlCode);
        }
    }

    // (CRT client: error names in the message, e.g. "(aws-c-io: AWS_IO_SOCKET_TIMEOUT)")

    if(message.find("TIMEOUT") != std::string::npos)
        return ERRORCOUNTS_KIND_TIMEOUT;

    for(const char* connFailName : {"CONNECTION_REFUSED", "NO_ROUTE_TO_HOST", "NETWORK_DOWN",
        "DNS_", "CONNECT_ABORTED", "NEGOTIATION_FAILURE"} )
    {
        if(message.find(connFailName) != std::string::npos)
            return ERRORCOUNTS_KIND_CONNFAIL;
    }

    for(const char* connResetName : {"SOCKET_CLOSED", "CONNECTION_CLOSED", "BROKEN_PIPE",
        "SOCKET_NOT_CONNECTED"} )
    {
        if(message.find(connResetName) != std::string::npos)
            return ERRORCOUNTS_KIND_CONNRESET;
    }

    // remaining transport failures without curl/CRT details, e.g. the SDK's own content-length
    // mismatch check, mean the connection broke before the response was complete
    if( (int)error.GetErrorType() == (int)Aws::Client::CoreErrors::NETWORK_CONNECTION)
        return ERRORCOUNTS_KIND_CONNRESET;

    return ERRORCOUNTS_KIND_OTHER;
}

#endif // S3_SUPPORT

#endif /* TOOLKITS_S3ERRORKIND_H_ */
