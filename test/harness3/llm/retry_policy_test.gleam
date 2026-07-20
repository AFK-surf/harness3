import harness3/llm
import harness3/llm/retry_policy

pub fn exponential_delay_is_capped_at_ten_seconds_test() {
  assert retry_policy.initial_delay_milliseconds() == 100
  assert retry_policy.next_delay_milliseconds(100) == 200
  assert retry_policy.next_delay_milliseconds(3200) == 6400
  assert retry_policy.next_delay_milliseconds(6400) == 10_000
  assert retry_policy.next_delay_milliseconds(10_000) == 10_000
}

pub fn transient_http_statuses_are_retryable_test() {
  assert retry_policy.status_is_retryable(408)
  assert retry_policy.status_is_retryable(409)
  assert retry_policy.status_is_retryable(425)
  assert retry_policy.status_is_retryable(429)
  assert retry_policy.status_is_retryable(500)
  assert retry_policy.status_is_retryable(503)
}

pub fn permanent_http_statuses_are_not_retryable_test() {
  assert !retry_policy.status_is_retryable(400)
  assert !retry_policy.status_is_retryable(401)
  assert !retry_policy.status_is_retryable(403)
  assert !retry_policy.status_is_retryable(501)
  assert !retry_policy.status_is_retryable(505)
}

pub fn provider_errors_are_classified_by_status_and_kind_test() {
  assert retry_policy.response_error_is_retryable(
    429,
    llm.ApiError(429, "rate_limit_error", "slow down"),
  )
  assert retry_policy.response_error_is_retryable(
    200,
    llm.ApiError(0, "overloaded_error", "busy"),
  )
  assert retry_policy.response_error_is_retryable(
    200,
    llm.InvalidResponse("truncated response"),
  )
  assert !retry_policy.response_error_is_retryable(
    400,
    llm.ApiError(400, "invalid_request_error", "bad request"),
  )
  assert !retry_policy.response_error_is_retryable(
    401,
    llm.ApiError(401, "authentication_error", "bad key"),
  )
  assert !retry_policy.response_error_is_retryable(
    400,
    llm.InvalidRequest("invalid request"),
  )
}
