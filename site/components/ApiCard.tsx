type ApiParam = {
  name: string;
  type: string;
  defaultValue?: string;
  description?: string;
};

type ApiCardProps = {
  locale?: 'ja' | 'en';
  kind?: string;
  name: string;
  signature?: string;
  syntax?: string;
  signatureLabel?: string;
  module?: string;
  source?: string;
  returns?: string;
  effects?: string;
  summary?: string;
  params?: ApiParam[];
};

const labels = {
  ja: {
    signature: 'シグネチャ',
    summary: '説明',
    module: 'モジュール',
    source: '定義',
    returns: '返り値',
    effects: '効果',
    params: '引数',
    name: '名前',
    type: '型',
    defaultValue: '既定値',
    description: '説明',
  },
  en: {
    signature: 'Signature',
    summary: 'Description',
    module: 'Module',
    source: 'Definition',
    returns: 'Returns',
    effects: 'Effects',
    params: 'Parameters',
    name: 'Name',
    type: 'Type',
    defaultValue: 'Default',
    description: 'Description',
  },
};

export function ApiCard({
  locale = 'ja',
  kind = 'function',
  name,
  signature,
  syntax,
  signatureLabel,
  module,
  source,
  returns,
  effects,
  summary,
  params = [],
}: ApiCardProps) {
  const l = labels[locale];
  const codeText = syntax ?? signature ?? '';
  const displayedSignatureLabel =
    signatureLabel ??
    (syntax || kind === 'syntax' || kind === 'declaration'
      ? locale === 'ja'
        ? '構文'
        : 'Syntax'
      : l.signature);

  if (import.meta.env.SSG_MD) {
    const metaLines = [
      module ? `- ${l.module}: ${module}` : null,
      source ? `- ${l.source}: ${source}` : null,
      returns ? `- ${l.returns}: ${returns}` : null,
      effects ? `- ${l.effects}: ${effects}` : null,
    ].filter(Boolean);
    const paramLines = params.map((param) => {
      const defaultText = param.defaultValue ? ` = ${param.defaultValue}` : '';
      const description = param.description ? `: ${param.description}` : '';
      return `- ${param.name}: ${param.type}${defaultText}${description}`;
    });

    return (
      <>
        {`### ${name}

${displayedSignatureLabel}

\`\`\`ss
${codeText}
\`\`\`

${summary ? `${summary}\n\n` : ''}${metaLines.length ? `${metaLines.join('\n')}\n\n` : ''}${paramLines.length ? `${l.params}\n${paramLines.join('\n')}\n` : ''}`}
      </>
    );
  }

  return (
    <section className="ss-api" aria-label={`${kind} ${name}`}>
      <div className="ss-api__header">
        <span className="ss-api__kind">{kind}</span>
        <span className="ss-api__name">{name}</span>
      </div>
      <div className="ss-api__body">
        <div className="ss-api__signature-label">{displayedSignatureLabel}</div>
        <pre className="ss-api__signature">
          <code>{codeText}</code>
        </pre>
        {summary ? (
          <p className="ss-api__summary">
            <span>{l.summary}: </span>
            {summary}
          </p>
        ) : null}
        <dl className="ss-api__meta">
          {module ? (
            <>
              <dt>{l.module}</dt>
              <dd>{module}</dd>
            </>
          ) : null}
          {source ? (
            <>
              <dt>{l.source}</dt>
              <dd>{source}</dd>
            </>
          ) : null}
          {returns ? (
            <>
              <dt>{l.returns}</dt>
              <dd>{returns}</dd>
            </>
          ) : null}
          {effects ? (
            <>
              <dt>{l.effects}</dt>
              <dd>{effects}</dd>
            </>
          ) : null}
        </dl>
        {params.length ? (
          <div className="ss-api__params">
            <div className="ss-api__params-title">{l.params}</div>
            <table>
              <thead>
                <tr>
                  <th>{l.name}</th>
                  <th>{l.type}</th>
                  <th>{l.defaultValue}</th>
                  <th>{l.description}</th>
                </tr>
              </thead>
              <tbody>
                {params.map((param) => (
                  <tr key={param.name}>
                    <td>
                      <code>{param.name}</code>
                    </td>
                    <td>
                      <code>{param.type}</code>
                    </td>
                    <td>{param.defaultValue ? <code>{param.defaultValue}</code> : ''}</td>
                    <td>{param.description || ''}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : null}
      </div>
    </section>
  );
}
