# elbencho CSV Results File

elbencho supports operations against both directories (for example `--mkdirs`) and files (for example `--write`). Each elbencho operation however only deals with one of these so the generic name `entry` is used in the CSV fields. See the `operation` column for the row to determine if the operation was working with directory or file `entries`.

As mentioned in the [main README file](README.md), elbencho presents two result columns: One showing the aggregate status at the point in time when the fastest I/O thread finished its work ("First Done") and one for the aggregate end result at the point in time when the slowest thread finished its work ("Last Done"). Results for each of these are stored separately in the CSV with columns appended with `[first]` and `[last]` respectively.

## Fields
* `ISO date` - timestamp when the row was written to the CSV file when the test completed
* `label` - the label, if any, specified for this run on the command line (see `--label`)
* `path type` - type of path passed into elbencho (dir or file)
* `paths` - number of paths passed into elbencho
* `hosts` - number of hosts generating load
* `threads` - number of threads _per host_ generating load
* `dirs` - number of directories _per thread_
* `files` - number of files _per thread_
* `file size` - size of the files in bytes
* `block size` - block size in bytes
* `direct IO` - 1 if direct IO is used, else 0
* `random` - 1 if random operations were used, else 0 (the default)
* `random aligned` - 1 if random operations were block size aligned (the default), 0 if they were not (see `--norandalign`) or blank if no random operations were used
* `IO depth` - IO depth used
* `shared paths` - 1 if the paths were shared by all hosts (the default), else 0 (see `--nosvcshare`)
* `truncate` - 1 if files were truncated before writing (see `--trunc`), else 0 (the default)
* `operation` - file operation being performed (READ, WRITE, etc)
* `time ms [first]` & `[last]` - time in milliseconds since the test started and the first and last thread finished
* `CPU% [first]` & `[last]` - CPU percentage of the run as seen by the first and last thread finished
* Operation results
  * `entries/s [first]` & `[last]` - number of entries per second for the first and last thread finished
  * `IOPS [first]` & `[last]` - number of IOPS for the first and last thread finished
  * `MiB/s [first]` & `[last]` - throughput in MiB/s for the first and last thread finished
  * `entries [first]` & `[last]` - total entries created by the first and last thread finished
  * `IOs [first]` & `[last]` - total number of I/O operations (blocks read or written, or S3 object requests, including failed requests when errors are ignored; not incremented by HEAD, list, delete or multipart create/complete requests) by the first and last thread finished
  * `MiB [first]` & `[last]` - total MiB read/written by the first and last thread finished
  * `Ent lat us [min]` & `[avg]` & `[max]` - time in microseconds to complete an entry (file or directory)
  * `IO lat us [min]` & `[avg]` & `[max]` - time in microseconds to complete an IOP, that is: IO latency
* When using `--rwmixpct` to do mixed reads and writes concurrently, the `entries/s` and related fields above report the data for the WRITE operations. The results of the READ operations are stored in the `rwmix read` fields.
  * `rwmix read entries/s [first]` & `[last]`
  * `rwmix read IOPS [first]` & `[last]`
  * `rwmix read MiB/s [first]` & `[last]`
  * `rwmix read entries [first]` & `[last]`
  * `rwmix read IOs [first]` & `[last]`
  * `rwmix read MiB [first]` & `[last]`
  * `rwmix read Ent lat us [min]` & `[avg]` & `[max]`
  * `rwmix read IO lat us [min]` & `[avg]` & `[max]`
* Error counts. These are only filled for phases in which S3 operations failed, e.g. when errors were ignored with `--s3ignoreerrors`, and are empty otherwise. Attempts that the AWS SDK retries on its own are not counted here, but separately as retries below; set `AWS_RETRY_MODE=standard` and `AWS_MAX_ATTEMPTS=1` in the environment of the elbencho process (or of each service instance) to count every failed request as an error instead. See the [S3 error counts guide](s3-error-counts.md) for what is and is not counted, and for how to compute an error rate.
  * `errors total` - number of failed S3 operations. Multipart-upload create and complete requests are counted here when they fail, but are not counted as IOs, so for multipart workloads `errors total` divided by `IOs [last]` slightly overstates the error rate.
  * `errors timeout` - number of failed operations that got no response before elbencho gave up waiting (see `--s3reqtimeout`)
  * `errors conn fail` - number of failed operations for which no connection to the endpoint could be established
  * `errors conn reset` - number of failed operations for which the connection broke before or during the response
  * `errors http 4xx` - number of failed operations with a 4xx HTTP status
  * `errors http 5xx` - number of failed operations with a 5xx HTTP status
  * `errors by kind` - all error kinds with their counts, separated by semicolons, e.g. `http_503=40;timeout=2`. Each HTTP status code is counted separately as `http_<code>`; `other` counts failures without an HTTP status that are neither a timeout, a connection failure nor a connection reset.
* Retry counts. These are only filled for phases in which the AWS SDK retried at least one request attempt, and are empty otherwise. See the "Retried attempts" section of the [S3 error counts guide](s3-error-counts.md) for what is and is not counted.
  * `retries total` - number of request attempts that the AWS SDK retried
  * `retries wait ms` - sum, across all attempts and all worker threads, of the backoff delay the AWS SDK waited before each retry; an upper bound on wait time, not the wall-clock time actually spent waiting, because worker threads retry concurrently, and it excludes a couple of other SDK-internal waits (see the [S3 error counts guide](s3-error-counts.md) for which)
  * `retries by kind` - all error kinds of the retried attempts with their counts, separated by semicolons, using the same kinds as `errors by kind`
* `version` - version of elbencho
* `command` - elbencho command line used
