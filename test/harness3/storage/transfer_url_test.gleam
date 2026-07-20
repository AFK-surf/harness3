import aws4_request
import gleam/http
import gleam/http/request.{Request}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness3/storage/gcs_sign
import harness3/storage/gcs_xml
import harness3/storage/s3_sign

pub fn s3_presigning_matches_aws_sigv4_reference_vector_test() {
  let signer =
    aws4_request.signer(
      access_key_id: "AKIAIOSFODNN7EXAMPLE",
      secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      region: "us-east-1",
      service: "s3",
    )
    |> aws4_request.with_date_time(#(#(2013, 5, 24), #(0, 0, 0)))
  let signed =
    Request(
      http.Get,
      [],
      <<>>,
      http.Https,
      "examplebucket.s3.amazonaws.com",
      None,
      "/test.txt",
      None,
    )
    |> s3_sign.presign(signer, _, 86_400)
  assert signed.query
    == Some(
      "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
    )
}

pub fn gcs_hmac_presigning_matches_independent_v4_vector_test() {
  let signer =
    gcs_sign.signer("GOOGTESTACCESS", "test-secret")
    |> gcs_sign.with_date_time(#(#(2026, 7, 20), #(12, 34, 56)))
  let signed =
    Request(
      http.Put,
      [],
      <<>>,
      http.Https,
      "storage.googleapis.com",
      None,
      "/bucket/path/object.txt",
      None,
    )
    |> gcs_sign.presign(signer, _, 300)
  assert signed.query
    == Some(
      "X-Goog-Algorithm=GOOG4-HMAC-SHA256&X-Goog-Credential=GOOGTESTACCESS%2F20260720%2Fauto%2Fstorage%2Fgoog4_request&X-Goog-Date=20260720T123456Z&X-Goog-Expires=300&X-Goog-SignedHeaders=host&X-Goog-Signature=a07c246b7a6b56181a718f4d6761822bc538da3fce3bfda80b7ba57a843e98ef",
    )
}

pub fn gcs_hmac_header_signing_covers_generation_preconditions_test() {
  let signer =
    gcs_sign.signer("GOOGTESTACCESS", "test-secret")
    |> gcs_sign.with_date_time(#(#(2026, 7, 20), #(12, 34, 56)))
  let signed =
    Request(
      http.Put,
      [#("x-goog-if-generation-match", "123")],
      <<>>,
      http.Https,
      "storage.googleapis.com",
      None,
      "/bucket/object.txt",
      None,
    )
    |> gcs_sign.sign(
      signer,
      _,
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    )
  let assert Ok(authorization) = list.key_find(signed.headers, "authorization")
  assert string.starts_with(authorization, "GOOG4-HMAC-SHA256 Credential=")
  assert string.contains(
    authorization,
    "SignedHeaders=host;x-goog-content-sha256;x-goog-date;x-goog-if-generation-match",
  )
}

pub fn gcs_xml_listing_preserves_generation_tokens_test() {
  let body = <<
    "<?xml version='1.0' encoding='utf-8'?><ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>notes/a.txt</Key><Generation>1360887759327000</Generation><LastModified>2026-07-20T12:34:56.000Z</LastModified><Size>4</Size></Contents></ListBucketResult>":utf8,
  >>
  let assert Ok(gcs_xml.Page(False, [object])) = gcs_xml.decode_page(body)
  assert object.key == "notes/a.txt"
  assert object.generation == "1360887759327000"
  assert object.size == 4
}
