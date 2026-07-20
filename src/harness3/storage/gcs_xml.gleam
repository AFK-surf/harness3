import bucket/internal/xml
import gleam/result
import gleam/string

pub type ListedObject {
  ListedObject(
    key: String,
    generation: String,
    last_modified: String,
    size: Int,
  )
}

pub type Page {
  Page(is_truncated: Bool, objects: List(ListedObject))
}

pub fn decode_page(body: BitArray) -> Result(Page, String) {
  let object =
    xml.element("Contents", ListedObject("", "", "", 0))
    |> xml.keep_text("Key", fn(object, key) { ListedObject(..object, key: key) })
    |> xml.keep_text("Generation", fn(object, generation) {
      ListedObject(..object, generation: generation)
    })
    |> xml.keep_text("LastModified", fn(object, modified) {
      ListedObject(..object, last_modified: modified)
    })
    |> xml.keep_int("Size", fn(object, size) {
      ListedObject(..object, size: size)
    })
  xml.element("ListBucketResult", Page(False, []))
  |> xml.keep_bool("IsTruncated", fn(page, truncated) {
    Page(..page, is_truncated: truncated)
  })
  |> xml.keep(object, fn(page, object) {
    Page(..page, objects: [object, ..page.objects])
  })
  |> xml.parse(body)
  |> result.map_error(string.inspect)
}
