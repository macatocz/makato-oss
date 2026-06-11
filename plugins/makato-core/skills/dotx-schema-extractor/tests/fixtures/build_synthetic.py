"""Build a tiny .dotx in memory containing one of every marker type.

Returns raw bytes — caller wraps in BytesIO. No external deps.
"""

from __future__ import annotations

import io
import zipfile

W_NS = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'

_CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
<Override PartName="/word/comments.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"/>
</Types>"""

_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>"""

_DOC_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments" Target="comments.xml"/>
</Relationships>"""

_COMMENTS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:comment w:id="0" w:author="VH" w:date="2024-09-30T12:00:00Z" w:initials="VH">
    <w:p><w:r><w:t>Replace with name of stavba</w:t></w:r></w:p>
  </w:comment>
</w:comments>"""

_DOC_XML = f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document {W_NS}>
  <w:body>
    <w:p>
      <w:r><w:t xml:space="preserve">Stavba: </w:t></w:r>
      <w:commentRangeStart w:id="0"/>
      <w:r><w:rPr><w:highlight w:val="cyan"/></w:rPr><w:t>Název stavby zde</w:t></w:r>
      <w:commentRangeEnd w:id="0"/>
      <w:r><w:commentReference w:id="0"/></w:r>
    </w:p>
    <w:p>
      <w:r><w:t xml:space="preserve">Termín: </w:t></w:r>
      <w:r><w:rPr><w:highlight w:val="yellow"/></w:rPr><w:t>DD.MM.RRRR</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:t xml:space="preserve">Pevný text bez markeru.</w:t></w:r>
    </w:p>
    <w:sectPr/>
  </w:body>
</w:document>"""


def build_synthetic_dotx() -> bytes:
    """Return a complete .dotx as bytes. Three paragraphs:

    1. Plain text + cyan-highlighted run anchored by a Word comment.
    2. Plain text + yellow-highlighted run, no comment.
    3. Plain text only — no markers.
    """
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", _CONTENT_TYPES)
        zf.writestr("_rels/.rels", _RELS)
        zf.writestr("word/_rels/document.xml.rels", _DOC_RELS)
        zf.writestr("word/document.xml", _DOC_XML)
        zf.writestr("word/comments.xml", _COMMENTS)
    return buf.getvalue()
