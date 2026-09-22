// SPDX-FileCopyrightText: 2020-2026 Sven Breuner and elbencho contributors
// SPDX-License-Identifier: GPL-3.0-only

#include <cstdlib>

#include "Common.h"
#include "ErrorCounts.h"

/**
 * Add a subtree with the total and one entry per error kind below "by_kind" to the given tree,
 * e.g. for the json results file. Callers only use this if there were any errors.
 *
 * @subtreeKey key of the subtree to add to outTree, e.g. "errors".
 * @waitMillis sum of backoff delays before the counted attempts; only written if writeWait is
 *      true, right after "total".
 * @writeWait true to add waitMillis as "wait_ms" to the subtree; used for the retries subtree.
 */
void ErrorCounts::getAsPropertyTreeForJSONFile(bpt::ptree& outTree, std::string subtreeKey,
	uint64_t waitMillis, bool writeWait) const
{
	bpt::ptree subtree;
	bpt::ptree byKindSubtree;

	subtree.put("total", getNumErrorsTotal() );

	if(writeWait)
		subtree.put("wait_ms", waitMillis);

	for(const auto& kindCountPair : counts)
		byKindSubtree.put(kindCountPair.first, kindCountPair.second);

	subtree.put_child("by_kind", byKindSubtree);

	outTree.put_child(subtreeKey, subtree);
}

/**
 * Sparse encoding for the transfer from service to master: one (kind, count) list item per error
 * kind that occurred, nothing at all if no error occurred.
 *
 * @itemKey key of an individual list item, e.g. XFER_STATS_ERRCOUNTLIST_ITEM for errors or
 *      XFER_STATS_RETRYCOUNTLIST_ITEM for retries.
 */
void ErrorCounts::getAsPropertyTreeForService(bpt::ptree& outTree, std::string itemKey) const
{
	for(const auto& kindCountPair : counts)
	{
		bpt::ptree listItem;

		listItem.put(XFER_STATS_ERRCOUNTLIST_ITEM_KIND, kindCountPair.first);
		listItem.put(XFER_STATS_ERRCOUNTLIST_ITEM_CNT, kindCountPair.second);

		outTree.add_child(itemKey, listItem);
	}
}

/**
 * Counterpart of getAsPropertyTreeForService(). A missing list means that no error occurred.
 *
 * A kind that is not 1-32 lowercase alphanumeric/underscore characters is folded into
 * ERRORCOUNTS_KIND_OTHER instead of being stored as-is, so that a service instance running a
 * different or compromised version cannot inject an arbitrarily large or malformed kind string
 * into the master's map.
 *
 * @listKey key of the list to read from tree, e.g. XFER_STATS_ERRCOUNTLIST for errors or
 *      XFER_STATS_RETRYCOUNTLIST for retries.
 */
void ErrorCounts::setFromPropertyTreeForService(bpt::ptree& tree, std::string listKey)
{
	counts.clear();

	auto listTree = tree.get_child_optional(listKey);
	if(!listTree)
		return;

	for(bpt::ptree::value_type& listItem : *listTree)
	{
		std::string kind = listItem.second.get<std::string>(XFER_STATS_ERRCOUNTLIST_ITEM_KIND);
		uint64_t count = listItem.second.get<uint64_t>(XFER_STATS_ERRCOUNTLIST_ITEM_CNT);

		bool isValidKind = !kind.empty() && (kind.length() <= 32) &&
			(kind.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789_") == std::string::npos);

		counts[isValidKind ? kind : ERRORCOUNTS_KIND_OTHER] += count;
	}
}

/**
 * All kinds with their counts in one line, e.g. "http_503=40 timeout=2" for the console or
 * "http_503=40;timeout=2" for the csv file.
 */
std::string ErrorCounts::getKindsStr(const std::string& kindSeparator,
	const std::string& countSeparator) const
{
	std::string result;

	for(const auto& kindCountPair : counts)
	{
		if(!result.empty() )
			result += kindSeparator;

		result += kindCountPair.first + countSeparator + std::to_string(kindCountPair.second);
	}

	return result;
}

/**
 * Sum of all "http_<code>" counts whose code falls into the given hundred, e.g. firstDigit=4 sums
 * "http_400".."http_499" for the "4xx" column.
 */
uint64_t ErrorCounts::getCountHttpClass(unsigned firstDigit) const
{
	const std::string prefix = ERRORCOUNTS_KIND_HTTP_PREFIX;
	const long classMin = firstDigit * 100;
	const long classMax = classMin + 99;
	uint64_t total = 0;

	for(const auto& kindCountPair : counts)
	{
		if(kindCountPair.first.compare(0, prefix.length(), prefix) != 0)
			continue;

		const char* codeStr = kindCountPair.first.c_str() + prefix.length();
		char* endPtr;

		long httpCode = strtol(codeStr, &endPtr, 10);

		// reject a suffix that strtol did not fully consume (e.g. "http_500abc"), that had no
		// digits at all, or that is not a plain 3-digit HTTP status, so a peer-supplied kind can't
		// be miscounted into a class
		if( (endPtr == codeStr) || (*endPtr != '\0') || (httpCode < 0) || (httpCode > 999) )
			continue;

		if( (httpCode >= classMin) && (httpCode <= classMax) )
			total += kindCountPair.second;
	}

	return total;
}

/**
 * Record one retried attempt, called from whichever thread executes the request.
 *
 * @kind error kind of the attempt that got retried, from S3Tk::errorToKindStr()/s3ErrorToKindStr().
 * @delayMillis backoff delay the retry strategy computed before this retry.
 */
void RetryCounts::addRetry(const std::string& kind, uint64_t delayMillis)
{
	std::lock_guard<std::mutex> lock(mutex);

	counts.addError(kind);
	waitMillis += delayMillis;
}

/**
 * @return copy of the current per-kind retry counts, for the owner to sum up at phase end.
 */
ErrorCounts RetryCounts::getCountsCopy() const
{
	std::lock_guard<std::mutex> lock(mutex);

	return counts;
}

uint64_t RetryCounts::getWaitMillis() const
{
	std::lock_guard<std::mutex> lock(mutex);

	return waitMillis;
}

/**
 * Replace the current counts, e.g. after parsing them from a service instance's result.
 */
void RetryCounts::set(const ErrorCounts& newCounts, uint64_t newWaitMillis)
{
	std::lock_guard<std::mutex> lock(mutex);

	counts = newCounts;
	waitMillis = newWaitMillis;
}

void RetryCounts::reset()
{
	std::lock_guard<std::mutex> lock(mutex);

	counts.reset();
	waitMillis = 0;
}
