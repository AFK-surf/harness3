/// A backend-specific version token used for optimistic concurrency control.
pub type VersionToken {
  S3Etag(etag: String)
  GcsGeneration(generation: String)
  LocalVersion(mtime_seconds: Int, generation: Int)
}

/// Metadata common to every storage backend.
pub type Metadata {
  Metadata(
    key: String,
    size: Int,
    modified_at: String,
    version: VersionToken,
  )
}

/// An object body and the metadata observed when it was read.
pub type Object {
  Object(metadata: Metadata, body: BitArray)
}

/// Controls whether a put may replace the current object.
pub type PutCondition {
  Unconditional
  IfAbsent
  IfUnchanged(version: VersionToken)
}

pub type Error {
  NotFound(key: String)
  PreconditionFailed(key: String)
  InvalidKey(key: String)
  InvalidCondition(expected_backend: String, actual_backend: String)
  Transport(reason: String)
  Backend(status: Int, message: String)
}

/// The storage interface. Backend modules construct this value.
pub opaque type Storage {
  Storage(
    get_object: fn(String) -> Result(Object, Error),
    head_object: fn(String) -> Result(Metadata, Error),
    put_object: fn(String, BitArray, PutCondition) -> Result(Metadata, Error),
    list_objects: fn(String) -> Result(List(Metadata), Error),
    delete_object: fn(String) -> Result(Nil, Error),
  )
}

pub fn from_functions(
  get get_object: fn(String) -> Result(Object, Error),
  head head_object: fn(String) -> Result(Metadata, Error),
  put put_object: fn(String, BitArray, PutCondition) -> Result(Metadata, Error),
  list list_objects: fn(String) -> Result(List(Metadata), Error),
  delete delete_object: fn(String) -> Result(Nil, Error),
) -> Storage {
  Storage(get_object, head_object, put_object, list_objects, delete_object)
}

pub fn get(storage: Storage, key: String) -> Result(Object, Error) {
  let Storage(get_object:, ..) = storage
  get_object(key)
}

pub fn head(storage: Storage, key: String) -> Result(Metadata, Error) {
  let Storage(head_object:, ..) = storage
  head_object(key)
}

pub fn put(
  storage: Storage,
  key: String,
  body: BitArray,
  condition: PutCondition,
) -> Result(Metadata, Error) {
  let Storage(put_object:, ..) = storage
  put_object(key, body, condition)
}

pub fn list(storage: Storage, prefix: String) -> Result(List(Metadata), Error) {
  let Storage(list_objects:, ..) = storage
  list_objects(prefix)
}

pub fn delete(storage: Storage, key: String) -> Result(Nil, Error) {
  let Storage(delete_object:, ..) = storage
  delete_object(key)
}
