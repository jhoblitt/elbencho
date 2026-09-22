// SPDX-FileCopyrightText: 2020-2026 Sven Breuner and elbencho contributors
// SPDX-License-Identifier: GPL-3.0-only

#ifndef ERRORCOUNTS_H_
#define ERRORCOUNTS_H_

#include <cstdint>
#include <map>
#include <mutex>
#include <string>

#include <boost/property_tree/ptree.hpp>

#include "Common.h"

namespace bpt = boost::property_tree;

#define ERRORCOUNTS_KIND_HTTP_PREFIX	"http_" // followed by the decimal http status code
#define ERRORCOUNTS_KIND_CURL_PREFIX	"curl_" // followed by an unmapped libcurl error code
#define ERRORCOUNTS_KIND_TIMEOUT		"timeout" // no response before this side gave up
#define ERRORCOUNTS_KIND_CONNFAIL		"conn_fail" // no connection to the endpoint
#define ERRORCOUNTS_KIND_CONNRESET		"conn_reset" // connection broke before/during the response
#define ERRORCOUNTS_KIND_OTHER			"other" // no http status, neither timeout nor conn fail

typedef std::map<std::string, uint64_t> ErrorKindCountMap;

/**
 * Number of failed operations of a benchmark phase per error kind. Error kinds are http status
 * codes ("http_<code>"), timeouts, connection failures/resets, unmapped curl error codes
 * ("curl_<n>") and a rest category. Only kinds that occurred at least once are stored, so an
 * empty map means that no error occurred.
 *
 * Used per worker and, summed up via operator+=, per host and per phase.
 */
class ErrorCounts
{
	public:
		void getAsPropertyTreeForJSONFile(bpt::ptree& outTree, std::string subtreeKey,
			uint64_t waitMillis = 0, bool writeWait = false) const;
		void getAsPropertyTreeForService(bpt::ptree& outTree,
			std::string itemKey = XFER_STATS_ERRCOUNTLIST_ITEM) const;
		void setFromPropertyTreeForService(bpt::ptree& tree,
			std::string listKey = XFER_STATS_ERRCOUNTLIST);
		std::string getKindsStr(const std::string& kindSeparator,
			const std::string& countSeparator) const;
		uint64_t getCountHttpClass(unsigned firstDigit) const;

	private:
		ErrorKindCountMap counts; // number of failed operations per error kind

	public: // inliners

		void addError(const std::string& kind)
		{
			counts[kind]++;
		}

		uint64_t getNumErrorsTotal() const
		{
			uint64_t total = 0;

			for(const auto& kindCountPair : counts)
				total += kindCountPair.second;

			return total;
		}

		uint64_t getCount(const std::string& kind) const
		{
			auto iter = counts.find(kind);

			return (iter == counts.end() ) ? 0 : iter->second;
		}

		void reset()
		{
			counts.clear();
		}

		ErrorCounts& operator+=(const ErrorCounts& rhs)
		{
			for(const auto& kindCountPair : rhs.counts)
				counts[kindCountPair.first] += kindCountPair.second;

			return *this;
		}
};

/**
 * Failed request attempts that the S3 client retried, per error kind, plus the sum of the backoff
 * delays before those retries. Filled by the retry strategy from whichever thread executes the
 * request, so all accesses are serialized by a mutex; read by the owner at phase end.
 */
class RetryCounts
{
	public:
		void addRetry(const std::string& kind, uint64_t delayMillis);
		ErrorCounts getCountsCopy() const;
		uint64_t getWaitMillis() const;
		void set(const ErrorCounts& newCounts, uint64_t newWaitMillis); // e.g. from a service
		void reset();

	private:
		mutable std::mutex mutex;
		ErrorCounts counts; // retried attempts per error kind
		uint64_t waitMillis{0}; // sum of backoff delays before the retries
};

#endif /* ERRORCOUNTS_H_ */
