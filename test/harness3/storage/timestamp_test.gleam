import harness3/storage/timestamp

pub fn http_date_seconds_test() {
  assert timestamp.http_date_seconds("Tue, 03 Jun 2025 12:00:00 GMT")
    == 1_748_952_000
  assert timestamp.http_date_seconds("") == 0
  assert timestamp.http_date_seconds("not a date") == 0
}

pub fn rfc3339_seconds_test() {
  assert timestamp.rfc3339_seconds("2025-06-03T12:00:00.000Z") == 1_748_952_000
  assert timestamp.rfc3339_seconds("2025-06-03T12:00:00Z") == 1_748_952_000
  assert timestamp.rfc3339_seconds("2025-06-03T13:00:00+01:00") == 1_748_952_000
  assert timestamp.rfc3339_seconds("") == 0
  assert timestamp.rfc3339_seconds("not a timestamp") == 0
}
