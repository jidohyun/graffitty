#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["reportlab"]
# ///
"""Rebuild the PDF; --refresh-video fetches the documented five-second fixture."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, PageBreak, Table, TableStyle


def make_document(destination):
    """Use a real portrait document, visibly distinct from the image preview."""
    ink = colors.HexColor("#202935")
    muted = colors.HexColor("#596675")
    styles = {
        "title": ParagraphStyle("title", fontName="Helvetica-Bold", fontSize=27, leading=32,
                                textColor=ink, spaceAfter=12),
        "subtitle": ParagraphStyle("subtitle", fontName="Helvetica", fontSize=10, leading=15,
                                   textColor=muted, spaceAfter=25),
        "heading": ParagraphStyle("heading", fontName="Helvetica-Bold", fontSize=14, leading=19,
                                  textColor=ink, spaceBefore=20, spaceAfter=9),
        "body": ParagraphStyle("body", fontName="Times-Roman", fontSize=13, leading=19,
                               textColor=ink, spaceAfter=12),
        "cell": ParagraphStyle("cell", fontName="Helvetica", fontSize=10, leading=15,
                               textColor=ink),
    }

    def paragraph(text, style="body"):
        return Paragraph(text, styles[style])

    def footer(pdf, document):
        pdf.saveState()
        pdf.setStrokeColor(colors.HexColor("#c8ced5"))
        pdf.line(48, 47, A4[0] - 48, 47)
        pdf.setFillColor(muted)
        pdf.setFont("Helvetica", 9)
        pdf.drawString(48, 31, "GRAFFITTY  /  WORKSPACE NOTES")
        pdf.drawRightString(A4[0] - 48, 31, f"{document.page} / 2")
        pdf.restoreState()

    document = SimpleDocTemplate(str(destination), pagesize=A4, leftMargin=48, rightMargin=48,
                                 topMargin=48, bottomMargin=65, title="Workspace layout",
                                 author="Graffitty", invariant=1)
    story = [
        paragraph("Workspace layout", "title"),
        paragraph("DESIGN NOTE 01  /  TERMINALS, FILES AND PREVIEWS", "subtitle"),
        paragraph("Overview", "heading"),
        paragraph("A workspace keeps related tools close together. The terminal, file tree and "
                  "document preview each occupy their own pane, so you can move between a file "
                  "and the command that uses it without leaving your work."),
        paragraph("1. Keep the working context visible", "heading"),
        paragraph("Place the file tree beside the active terminal. As you change directories, "
                  "the tree follows the terminal's working directory. Open a text file to edit "
                  "it in Neovim, or select an image, video or PDF to view it in Chromium."),
        paragraph("2. Give each surface a clear role", "heading"),
        paragraph("Use Main View for the panes you are working with now. Resize a preview when "
                  "you need to inspect a document, then return to the surrounding workspace."),
    ]
    rows = [[paragraph(a, "cell"), paragraph(b, "cell")] for a, b in [
        ("SURFACE", "PURPOSE"),
        ("File tree", "Browse folders, rename files and send paths to a terminal."),
        ("Terminal", "Run commands and keep the current working context."),
        ("Chromium", "Read documents and inspect local previews beside your code."),
    ]]
    table = Table(rows, colWidths=[110, A4[0] - 206], hAlign="LEFT")
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#eef1f4")),
        ("LINEBELOW", (0, 0), (-1, 0), .7, colors.HexColor("#aeb9c5")),
        ("LINEBELOW", (0, 1), (-1, -1), .4, colors.HexColor("#d9dfe5")),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 10),
        ("RIGHTPADDING", (0, 0), (-1, -1), 10),
        ("TOPPADDING", (0, 0), (-1, -1), 10),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 10),
    ]))
    story.extend([
        Spacer(1, 6), table, PageBreak(),
        paragraph("Working with files", "title"),
        paragraph("DESIGN NOTE 01  /  PRACTICAL WORKFLOW", "subtitle"),
        paragraph("3. Open a document beside the terminal", "heading"),
        paragraph("Select a PDF in the file tree to open it in Chromium. The document keeps "
                  "its page layout, text and page numbers. Use the viewer's thumbnails to "
                  "navigate between pages, or adjust the zoom to read a section more closely."),
        paragraph("4. Send a path to the pane that needs it", "heading"),
        paragraph("A selected file or directory can be sent to another terminal pane. This "
                  "keeps navigation in the file tree and command entry in the terminal, "
                  "without repeatedly copying paths by hand."),
        paragraph("5. Keep related work together", "heading"),
        paragraph("Leave useful documents open while you edit. Give a separate task its own "
                  "tab so that its terminals, previews and agents remain grouped together. "
                  "Return to that tab when you are ready to continue."),
    ])
    document.build(story, onFirstPage=footer, onLaterPages=footer)

assets = Path(__file__).resolve().parents[2] / "assets"
fixtures = assets / "fixtures"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--refresh-video", action="store_true", help="Download the source into temporary storage and replace only the cut video")
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix="graffitty-demo-media-") as folder:
    temp = Path(folder)
    make_document(temp / "layout.pdf")
    if args.refresh_video:
        source = json.loads(Path(__file__).with_name("video-source.json").read_text())
        original = temp / "source.webm"
        subprocess.run([
            "uvx", "--from", "yt-dlp[default]", "yt-dlp", "--no-playlist",
            "--download-sections", f"*{source['start_seconds']}-{source['end_seconds']}",
            "--force-keyframes-at-cuts",
            "--downloader-args", "ffmpeg_o:-c:v libvpx-vp9 -b:v 0 -crf 24 -deadline good -cpu-used 4 -row-mt 1 -an -loglevel error",
            "-f", source["format_id"], "-o", str(original), source["url"],
        ], check=True)
        subprocess.run([
            "ffmpeg", "-v", "error", "-y",
            "-i", str(original), "-t", str(source["end_seconds"] - source["start_seconds"]),
            "-map", "0:v:0", "-c:v", "copy", "-an", str(temp / "video.webm"),
        ], check=True)
        probe = json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,r_frame_rate,nb_read_frames", "-of", "json", str(temp / "video.webm"),
        ]))["streams"][0]
        assert (probe["width"], probe["height"], probe["r_frame_rate"], int(probe["nb_read_frames"])) == (1920, 1080, "60/1", 300), probe
        (temp / "video.webm").replace(fixtures / "video.webm")
    (temp / "layout.pdf").replace(fixtures / "layout.pdf")
