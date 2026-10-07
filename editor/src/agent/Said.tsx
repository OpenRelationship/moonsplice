// What the agent said, drawn as the markdown it is written in. Models answer in markdown (bold,
// lists, code, the odd table), and printing it as plain text left the asterisks and hashes on
// screen. react-markdown builds React elements and never renders raw HTML, so nothing in a
// model's answer can put markup of its own into the window.

import type { Components } from "react-markdown";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

const parts: Components = {
  p: ({ children }) => <p className="py-0.5">{children}</p>,
  strong: ({ children }) => <strong className="font-semibold text-[var(--text-1)]">{children}</strong>,
  em: ({ children }) => <em className="italic">{children}</em>,
  h1: ({ children }) => <p className="pt-1.5 pb-0.5 text-[13px] font-semibold">{children}</p>,
  h2: ({ children }) => <p className="pt-1.5 pb-0.5 text-[13px] font-semibold">{children}</p>,
  h3: ({ children }) => <p className="pt-1 pb-0.5 font-semibold">{children}</p>,
  h4: ({ children }) => <p className="pt-1 pb-0.5 font-semibold">{children}</p>,
  ul: ({ children }) => <ul className="list-disc py-0.5 pl-4">{children}</ul>,
  ol: ({ children }) => <ol className="list-decimal py-0.5 pl-4">{children}</ol>,
  li: ({ children }) => <li className="py-[1px]">{children}</li>,
  hr: () => <hr className="my-1.5 border-[var(--ink-4)]" />,
  blockquote: ({ children }) => (
    <blockquote className="border-l-2 border-[var(--ink-4)] pl-2 text-[var(--text-2)]">{children}</blockquote>
  ),
  code: ({ children, className }) =>
    className ? (
      <code className={className}>{children}</code>
    ) : (
      <code className="rounded-[3px] bg-[var(--ink-3)] px-1 py-[1px] font-mono text-[11.5px]">{children}</code>
    ),
  pre: ({ children }) => (
    <pre className="my-1 overflow-x-auto rounded-[var(--radius-sm)] bg-[var(--ink-2)] p-2 font-mono text-[11.5px] leading-[1.45]">
      {children}
    </pre>
  ),
  // A link opens nowhere from here: the window is not a browser, and a model's link is not one the
  // person chose. The address stays readable.
  a: ({ children, href }) => (
    <span className="underline decoration-[var(--text-3)]" title={href}>
      {children}
    </span>
  ),
  table: ({ children }) => (
    <div className="my-1 overflow-x-auto">
      <table className="border-collapse text-[11.5px]">{children}</table>
    </div>
  ),
  th: ({ children }) => (
    <th className="border border-[var(--ink-4)] px-1.5 py-0.5 text-left font-semibold">{children}</th>
  ),
  td: ({ children }) => <td className="border border-[var(--ink-4)] px-1.5 py-0.5">{children}</td>,
  img: ({ alt }) => <span>{alt}</span>,
};

export function Said({ text }: { text: string }) {
  return (
    <div className="text-[12.5px] leading-[1.5] text-[var(--text-1)]">
      <ReactMarkdown remarkPlugins={[remarkGfm]} components={parts}>
        {text}
      </ReactMarkdown>
    </div>
  );
}
