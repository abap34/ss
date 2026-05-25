import { CodeBlock } from '@rspress/core/theme';
import samples from '../generated/samples.json';

type Sample = {
  title: string;
  source: string;
  highlightedSource: string;
  sourcePath: string;
  pdf: string;
  image: string;
  ssVersion: string;
};

type Props = {
  id: keyof typeof samples;
  title?: string;
  pdfLabel?: string;
  sourceLabel?: string;
  generatedPdfLabel?: string;
  previewImageLabel?: string;
  rendererLabel?: string;
};

export function SsExample({
  id,
  title,
  pdfLabel = 'Open PDF',
  sourceLabel = 'Source file',
  generatedPdfLabel = 'Generated PDF',
  previewImageLabel = 'Preview image',
  rendererLabel = 'Renderer',
}: Props) {
  const sample = (samples as Record<string, Sample>)[String(id)];

  if (!sample) {
    return <p>Sample not found: {String(id)}</p>;
  }

  const displayTitle = title || sample.title;

  if (import.meta.env.SSG_MD) {
    return (
      <>
        {`### ${displayTitle}

${sourceLabel}: ${sample.sourcePath}

\`\`\`ss
${sample.source.trimEnd()}
\`\`\`

${generatedPdfLabel}: ${sample.pdf}
${previewImageLabel}: ${sample.image}
${rendererLabel}: ${sample.ssVersion}
`}
      </>
    );
  }

  return (
    <div className="ss-example">
      <div className="ss-example__source" aria-label={`${displayTitle} source`}>
        <CodeBlock title={`${displayTitle} · ${sample.sourcePath}`} lang="ss" wrapCode>
          <div dangerouslySetInnerHTML={{ __html: sample.highlightedSource }} />
        </CodeBlock>
      </div>
      <figure className="ss-example__preview">
        <a href={sample.pdf}>
          <img src={sample.image} alt={`${displayTitle} rendered preview`} />
        </a>
        <figcaption className="ss-example__caption">
          <a href={sample.pdf}>{pdfLabel}</a>
          <span> · {sample.ssVersion}</span>
        </figcaption>
      </figure>
    </div>
  );
}
