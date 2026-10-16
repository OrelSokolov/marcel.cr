# Перенос lib/marcel/mime_type/definitions.rb гема (1:1).

Marcel::MimeType.extend "text/plain", extensions: %w(txt asc)

Marcel::MimeType.extend "image/vnd.adobe.photoshop",
  magic: [Marcel::MagicRule.new(0, "8BPS".to_slice)], extensions: %w(psd psb)

Marcel::MimeType.extend "application/vnd.ms-excel", parents: "application/x-ole-storage"
Marcel::MimeType.extend "application/vnd.ms-powerpoint", parents: "application/x-ole-storage"

Marcel::MimeType.extend "application/vnd.openxmlformats-officedocument.wordprocessingml.document", parents: "application/zip"
Marcel::MimeType.extend "application/vnd.openxmlformats-officedocument.wordprocessingml.template", parents: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
Marcel::MimeType.extend "application/vnd.ms-word.document.macroenabled.12", parents: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
Marcel::MimeType.extend "application/vnd.ms-word.template.macroenabled.12", parents: %w(application/vnd.openxmlformats-officedocument.wordprocessingml.document application/vnd.ms-word.document.macroenabled.12)

Marcel::MimeType.extend "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", parents: "application/zip"
Marcel::MimeType.extend "application/vnd.openxmlformats-officedocument.spreadsheetml.template", parents: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
Marcel::MimeType.extend "application/vnd.ms-excel.sheet.macroenabled.12", parents: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
Marcel::MimeType.extend "application/vnd.ms-excel.template.macroenabled.12", parents: %w(application/vnd.openxmlformats-officedocument.spreadsheetml.sheet application/vnd.ms-excel.sheet.macroenabled.12)
Marcel::MimeType.extend "application/vnd.ms-excel.addin.macroenabled.12", parents: %w(application/vnd.openxmlformats-officedocument.spreadsheetml.sheet application/vnd.ms-excel.sheet.macroenabled.12)
Marcel::MimeType.extend "application/vnd.ms-excel.sheet.binary.macroenabled.12", parents: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

Marcel::MimeType.extend "application/vnd.openxmlformats-officedocument.presentationml.presentation", parents: "application/zip"
Marcel::MimeType.extend "application/vnd.openxmlformats-officedocument.presentationml.template", parents: "application/vnd.openxmlformats-officedocument.presentationml.presentation"
Marcel::MimeType.extend "application/vnd.openxmlformats-officedocument.presentationml.slideshow", parents: "application/vnd.openxmlformats-officedocument.presentationml.presentation"
Marcel::MimeType.extend "application/vnd.ms-powerpoint.addin.macroenabled.12", parents: %w(application/vnd.openxmlformats-officedocument.presentationml.presentation application/vnd.ms-powerpoint.presentation.macroenabled.12)
Marcel::MimeType.extend "application/vnd.ms-powerpoint.presentation.macroenabled.12", parents: "application/vnd.openxmlformats-officedocument.presentationml.presentation"
Marcel::MimeType.extend "application/vnd.ms-powerpoint.template.macroenabled.12", parents: %w(application/vnd.openxmlformats-officedocument.presentationml.presentation application/vnd.ms-powerpoint.presentation.macroenabled.12)
Marcel::MimeType.extend "application/vnd.ms-powerpoint.slideshow.macroenabled.12", parents: %w(application/vnd.openxmlformats-officedocument.presentationml.presentation application/vnd.ms-powerpoint.presentation.macroenabled.12)

Marcel::MimeType.extend "application/vnd.apple.pages", parents: "application/zip"
Marcel::MimeType.extend "application/vnd.apple.numbers", parents: "application/zip"
Marcel::MimeType.extend "application/vnd.apple.keynote", parents: "application/zip"

Marcel::MimeType.extend("audio/ogg", extensions: %w(opus),
  magic: [Marcel::MagicRule.new(0, "OggS".to_slice, [Marcel::MagicRule.new(28, "OpusHead".to_slice)])])
Marcel::MimeType.extend("audio/ogg", extensions: %w(ogg oga),
  magic: [Marcel::MagicRule.new(0, "OggS".to_slice, [Marcel::MagicRule.new(29, "vorbis".to_slice)])])

# Prefer the types browsers actually use over Tika's historical canonical types,
# keeping their file extensions and magic byte matchers.
Marcel::MimeType.canonicalize "audio/aac", instead_of: "audio/x-aac"
Marcel::MimeType.canonicalize "audio/flac", instead_of: "audio/x-flac"
Marcel::MimeType.canonicalize "audio/x-wav", instead_of: "audio/vnd.wave"

# Prefer IANA-registered types where Tika canonicalizes on a deprecated or private-tree name.
Marcel::MimeType.canonicalize "application/yaml", instead_of: "text/x-yaml" # RFC 9512
Marcel::MimeType.canonicalize "application/vnd.debian.binary-package", instead_of: "application/x-debian-package"
Marcel::MimeType.canonicalize "application/xliff+xml", instead_of: "application/x-xliff+xml"

Marcel::MimeType.extend "image/vnd.dwg", magic: [Marcel::MagicRule.new(0, "AC10".to_slice)]
Marcel::MimeType.extend "application/pkcs8", magic: [Marcel::MagicRule.new(0, "-----BEGIN PRIVATE KEY-----".to_slice)], extensions: %w(p8)

# Tika aliases this to application/x-x509-cert; the generated tables deliberately skip that
# alias so Marcel can reuse the name for PEM-format certificates via a ;format=pem subtype.
Marcel::MimeType.extend "application/x-x509-ca-cert",
  magic: [Marcel::MagicRule.new(0, "-----BEGIN CERTIFICATE-----".to_slice)],
  extensions: %w(pem), parents: "application/x-x509-cert;format=pem"

# Re-registering these matchers promotes them ahead of video/quicktime's broad ftyp match.
Marcel::MimeType.extend "image/avif", magic: [Marcel::MagicRule.new(4, "ftypavif".to_slice)]
Marcel::MimeType.extend "image/avif", magic: [Marcel::MagicRule.new(4, "ftypavis".to_slice)]
Marcel::MimeType.extend "image/heif", magic: [Marcel::MagicRule.new(4, "ftypmif1".to_slice)]
Marcel::MimeType.extend "image/heic", magic: [Marcel::MagicRule.new(4, "ftypheic".to_slice)]

Marcel::MimeType.extend "image/x-raw-sony",
  magic: [
    Marcel::MagicRule.new(0, "II*\x00".to_slice, [Marcel::MagicRule.new(0..4096, "SONY".to_slice)]),
    Marcel::MagicRule.new(0, "MM\x00*".to_slice, [Marcel::MagicRule.new(0..4096, "SONY".to_slice)]),
  ],
  extensions: %w(arw), parents: "image/tiff"
# CRW only: .cr2 belongs to image/x-canon-cr2, which Tika matches by magic (TIFF header
# plus CR marker at offset 8) and already subclasses image/tiff.
Marcel::MimeType.extend "image/x-raw-canon", parents: "image/tiff"

Marcel::MimeType.extend "video/mp4", magic: [Marcel::MagicRule.new(4, "ftypisom".to_slice), Marcel::MagicRule.new(4, "ftypM4V ".to_slice)], extensions: %w(mp4 m4v)

Marcel::MimeType.extend "audio/mpc", magic: [Marcel::MagicRule.new(0, "MPCKSH".to_slice)], extensions: %w(mpc)

Marcel::MimeType.extend "font/ttf", magic: [Marcel::MagicRule.new(0, "\x00\x01\x00\x00".to_slice)], extensions: %w(ttf ttc)
Marcel::MimeType.extend "font/otf", magic: [Marcel::MagicRule.new(0, "OTTO".to_slice)], extensions: %w(otf), parents: "font/ttf"
Marcel::MimeType.extend "application/vnd.adobe.flash.movie", magic: [Marcel::MagicRule.new(0, "FWS".to_slice), Marcel::MagicRule.new(0, "CWS".to_slice)], extensions: %w(swf)
Marcel::MimeType.extend "application/sql", extensions: %w(sql)
Marcel::MimeType.extend "text/vcard", magic: [Marcel::MagicRule.new(0, "BEGIN:VCARD".to_slice)], extensions: %w(vcf), parents: "text/plain"

Marcel::MimeType.extend(
  "application/vnd.ms-access",
  extensions: %w(mdb mde accdb accde),
  magic: [
    Marcel::MagicRule.new(0, "\x00\x01\x00\x00Standard Jet DB".to_slice),
    Marcel::MagicRule.new(0, "\x00\x01\x00\x00Standard ACE DB".to_slice),
  ],
  parents: "application/x-msaccess"
)

Marcel::MimeType.extend "text/markdown", parents: "text/x-web-markdown"
