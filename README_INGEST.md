Offline File Ingest + Summarization Pipeline (MLX + SQLite)

Overview
- Drag/drop large files (PDF, DOCX, HTML, TXT), normalize to clean text, chunk by pages/sections, index into SQLite (FTS5 + 384-dim vectors), and run offline hybrid retrieval + map-reduce summarization using MLX.

Structure
- Core/API.swift — Public protocols and types (Ingestor/Retriever/Summarizer)
- Core/Storage/Schema.sql — SQLite schema + FTS triggers
- Core/Storage/Database.swift — SQLite wrapper
- Core/Utils/Hashing.swift — Hash helper
- Core/Utils/Bookmarks.swift — Security-scoped bookmarks helper
- Core/Ingestion/PDFIngestor.swift — FileIngestor (PDF+OCR, DOCX, HTML, TXT)
- Core/Chunking/TextChunker.swift — Section-aware chunker
- Core/LLM/Embedder.swift — Local embedding (stub; swap with MLX model)
- Core/Index/Indexer.swift — Dedupe, insert, embed
- Core/Retrieval/HybridRetriever.swift — FTS5 prefilter + cosine re-rank
- Core/Summarization/MapReduceSummarizer.swift — Map-reduce summarizer + JSON extraction
- App/DocumentDemoView.swift — Minimal demo UI with drag/drop and summary display

Setup
1) Ensure the app links PDFKit, Vision, Accelerate, SQLite3.
2) Place MLX models under the app bundle as desired (LLM for generation; embeddings optional).
3) Database stored under: ~/Library/Application Support/agent-lux/Index/index.sqlite3

Usage
- Construct: let indexer = Indexer(); let ingestor = FileIngestor(indexer: indexer)
- Ingest: let docId = try await ingestor.ingest(url: fileURL)
- Query: let retr = HybridRetriever(); let hits = try await retr.search(query: "…", k: 6)
- Summarize: let sum = MapReduceSummarizer(); let bullets = try await sum.summarize(docId: docId, style: .bullets)
- Extract JSON: try await sum.extract(docId: docId, schema: schemaString)

Notes
- Embeddings are stubbed (hashed BoW, L2 normalized). Replace Core/LLM/Embedder.swift with MLX embedding model for better retrieval.
- OCR uses Vision on PDF page thumbnails when PDF text is empty.
- FTS5 triggers keep chunks_fts in sync.
- Security-scoped bookmarks persist file access; docs.bookmark stores the bookmark blob.
- All operations are local; no network calls.

Done when
- Drop a PDF into DocumentDemoView, watch progress text, receive 5–7 bullet summary with citations like [p.3].
- JSON extraction returns valid JSON per schema.
- Citations map to page numbers; you can open PDFs and jump to the page using the bookmark and PDFKit (integration left to the app).

