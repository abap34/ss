import { aborted, RenderQueue, waitForAbort } from "@ss/pdf/queue";

const maximumConcurrentRenders = 2;
const maximumCachedDocuments = 8;

export class PdfService {
  constructor(pdfjsProvider, workerSource) {
    this.pdfjsProvider = pdfjsProvider;
    this.workerSource = workerSource;
    this.pdfjsPromise = null;
    this.worker = null;
    this.workerPort = null;
    this.workerEntryUrl = null;
    this.documents = new Map();
    this.retiredDocuments = new Set();
    this.queue = new RenderQueue(maximumConcurrentRenders);
    this.clock = 0;
    this.disposed = false;
    this.destroyPromise = null;
  }

  schedule(priority, body, signal) {
    if (this.disposed) return Promise.reject(new Error("PDF service was disposed"));
    return this.queue.enqueue(priority, body, signal);
  }

  async pdfjs() {
    if (this.disposed) throw new Error("PDF service was disposed");
    if (!this.pdfjsPromise) {
      this.pdfjsPromise = Promise.resolve(
        typeof this.pdfjsProvider === "function"
          ? this.pdfjsProvider()
          : this.pdfjsProvider,
      ).then((pdfjs) => {
        if (this.disposed) throw new Error("PDF service was disposed");
        const workerOptions = pdfjs?.GlobalWorkerOptions;
        if (typeof pdfjs?.getDocument !== "function" ||
            typeof pdfjs.PDFWorker !== "function" ||
            workerOptions === null ||
            (typeof workerOptions !== "function" &&
              typeof workerOptions !== "object")) {
          throw new Error("PDF.js worker API is unavailable");
        }
        workerOptions.workerSrc = this.workerSource;
        const entry = workerEntryPoint(this.workerSource);
        let port = null;
        try {
          port = new Worker(entry.url, { type: "module" });
          this.worker = new pdfjs.PDFWorker({
            name: "ss-pdf-worker",
            port,
          });
          this.workerPort = port;
          this.workerEntryUrl = entry.owned ? entry.url : null;
        } catch (error) {
          port?.terminate();
          if (entry.owned) URL.revokeObjectURL(entry.url);
          throw error;
        }
        return pdfjs;
      }).catch((error) => {
        this.pdfjsPromise = null;
        this.destroyWorker();
        throw error;
      });
    }
    return this.pdfjsPromise;
  }

  async usePage(source, pageNumber, body, signal) {
    if (this.disposed) throw new Error("PDF service was disposed");
    const pdfjs = await waitForAbort(this.pdfjs(), signal);
    if (pdfjs === aborted) return;
    if (this.disposed) throw new Error("PDF service was disposed");
    const entry = this.document(source, pdfjs);
    entry.users += 1;
    entry.lastUsed = ++this.clock;
    this.trimDocuments();
    try {
      const pdf = await waitForAbort(entry.promise, signal);
      if (pdf === aborted) return;
      let page = entry.pages.get(pageNumber);
      if (!page) {
        page = pdf.getPage(pageNumber);
        entry.pages.set(pageNumber, page);
        page.catch(() => {
          if (entry.pages.get(pageNumber) === page) {
            entry.pages.delete(pageNumber);
          }
        });
      }
      const resolvedPage = await waitForAbort(page, signal);
      if (resolvedPage === aborted) return;
      return await body(resolvedPage, pdfjs);
    } finally {
      entry.users -= 1;
      entry.lastUsed = ++this.clock;
      this.trimDocuments();
    }
  }

  document(source, pdfjs) {
    let entry = this.documents.get(source);
    if (entry) return entry;

    const parameters = {
      url: source,
      isEvalSupported: false,
    };
    if (this.worker) parameters.worker = this.worker;
    const loadingTask = pdfjs.getDocument(parameters);
    entry = {
      loadingTask,
      promise: null,
      pages: new Map(),
      users: 0,
      lastUsed: ++this.clock,
      retirement: null,
    };
    entry.promise = loadingTask.promise.catch((error) => {
      if (this.documents.get(source) === entry) this.documents.delete(source);
      this.retireDocument(entry);
      throw error;
    });
    this.documents.set(source, entry);
    return entry;
  }

  trimDocuments() {
    if (this.documents.size <= maximumCachedDocuments) return;
    const unused = [...this.documents.entries()]
      .filter(([, entry]) => entry.users === 0)
      .sort((left, right) => left[1].lastUsed - right[1].lastUsed);
    while (this.documents.size > maximumCachedDocuments && unused.length > 0) {
      const [source, entry] = unused.shift();
      if (this.documents.get(source) !== entry || entry.users !== 0) continue;
      this.documents.delete(source);
      this.retireDocument(entry);
    }
  }

  destroy() {
    if (this.destroyPromise) return this.destroyPromise;
    this.disposed = true;
    const queueDrain = this.queue.close();
    for (const entry of this.documents.values()) this.retireDocument(entry);
    this.documents.clear();
    this.destroyPromise = queueDrain.then(async () => {
      await Promise.allSettled([...this.retiredDocuments]);
      this.destroyWorker();
    });
    return this.destroyPromise;
  }

  retireDocument(entry) {
    if (entry.retirement) return entry.retirement;
    const retirement = destroyDocumentEntry(entry);
    entry.retirement = retirement;
    this.retiredDocuments.add(retirement);
    void retirement.then(() => {
      this.retiredDocuments.delete(retirement);
    });
    return retirement;
  }

  destroyWorker() {
    try {
      this.worker?.destroy();
    } catch {}
    try {
      this.workerPort?.terminate();
    } catch {}
    if (this.workerEntryUrl) URL.revokeObjectURL(this.workerEntryUrl);
    this.worker = null;
    this.workerPort = null;
    this.workerEntryUrl = null;
  }
}

function destroyDocumentEntry(entry) {
  entry.pages.clear();
  return destroyLoadingTask(entry.loadingTask);
}

function destroyLoadingTask(task) {
  try {
    return Promise.resolve(task.destroy()).catch(() => {});
  } catch {
    return Promise.resolve();
  }
}

function workerEntryPoint(source) {
  const base = globalThis.location?.href;
  const resolved = new URL(source, base).href;
  if (resolved.startsWith("data:")) {
    return { url: resolved, owned: false };
  }
  if (base) {
    const pageOrigin = new URL(base).origin;
    const workerOrigin = new URL(resolved).origin;
    if (pageOrigin !== "null" && workerOrigin === pageOrigin) {
      return { url: resolved, owned: false };
    }
  }
  const wrapper = "await import(" + JSON.stringify(resolved) + ");";
  return {
    url: URL.createObjectURL(new Blob([wrapper], { type: "text/javascript" })),
    owned: true,
  };
}
