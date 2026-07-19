import { PdfRenderController } from "@ss/pdf/controller";
import { PdfService } from "@ss/pdf/service";

const controllers = new WeakMap();
const activeControllers = new Set();
const services = new Map();

export function mountPdfPages(root, pdfjsProvider, workerSource, options = {}) {
  controllers.get(root)?.destroy();
  let controller;
  controller = new PdfRenderController(
    root,
    serviceFor(pdfjsProvider, workerSource),
    options,
    () => {
      activeControllers.delete(controller);
      if (controllers.get(root) === controller) controllers.delete(root);
    },
  );
  controllers.set(root, controller);
  activeControllers.add(controller);
  controller.ready = controller.start();
  return controller;
}

export async function renderPdfPages(root, pdfjsProvider, workerSource, options = {}) {
  const controller = mountPdfPages(root, pdfjsProvider, workerSource, options);
  await controller.ready;
  return controller;
}

export async function disposePdfRuntime() {
  for (const controller of [...activeControllers]) controller.destroy();
  activeControllers.clear();
  const retiring = [...services.values()];
  services.clear();
  await Promise.allSettled(retiring.map((service) => service.destroy()));
}

function serviceFor(pdfjsProvider, workerSource) {
  let service = services.get(workerSource);
  if (!service) {
    service = new PdfService(pdfjsProvider, workerSource);
    services.set(workerSource, service);
  }
  return service;
}
