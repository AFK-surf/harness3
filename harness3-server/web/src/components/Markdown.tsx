import { createElement, type ComponentPropsWithoutRef, type JSX } from "react";
import ReactMarkdown, { type ExtraProps } from "react-markdown";
import remarkGfm from "remark-gfm";

const remarkPlugins = [remarkGfm];

const inlineCode =
  "rounded border border-line-soft bg-[#101315] px-[4px] py-[1px] font-mono text-[11px] text-[#c4ccc6]";

/** Maps a markdown element to `tag` with fixed classes and attributes,
 * dropping react-markdown's non-DOM `node` prop. */
function themed<Tag extends keyof JSX.IntrinsicElements>(
  tag: Tag,
  className: string,
  attributes?: ComponentPropsWithoutRef<Tag>,
) {
  return ({ node: _node, ...props }: ComponentPropsWithoutRef<Tag> & ExtraProps) =>
    createElement(tag, { className, ...attributes, ...props });
}

const components = {
  p: themed("p", "my-[10px]"),
  a: themed(
    "a",
    "text-accent underline decoration-[#4a5c3d] underline-offset-2 hover:decoration-accent",
    { target: "_blank", rel: "noreferrer noopener" },
  ),
  ul: themed("ul", "my-[10px] list-disc pl-[22px]"),
  ol: themed("ol", "my-[10px] list-decimal pl-[22px]"),
  li: themed("li", "my-[3px] [&>ul]:my-[3px] [&>ol]:my-[3px]"),
  h1: themed("h2", "mt-[18px] mb-[8px] text-[16px] font-bold text-ink"),
  h2: themed("h3", "mt-[16px] mb-[7px] text-[15px] font-bold text-ink"),
  h3: themed("h4", "mt-[14px] mb-[6px] text-[14px] font-bold text-ink"),
  h4: themed("h5", "mt-[12px] mb-[5px] text-[13px] font-bold text-ink"),
  h5: themed("h6", "mt-[12px] mb-[5px] text-[13px] font-semibold text-ink"),
  h6: themed("h6", "mt-[12px] mb-[5px] text-[13px] font-semibold text-muted"),
  blockquote: themed("blockquote", "my-[10px] border-l-2 border-[#3c4934] pl-[11px] text-muted"),
  hr: themed("hr", "my-[14px] border-line-soft"),
  pre: themed(
    "pre",
    "my-[10px] max-h-80 overflow-auto rounded-[9px] border border-line bg-[#101315] p-[10px] font-mono text-[11px] leading-[1.55] text-[#b8c0bb] whitespace-pre-wrap break-words [&_code]:rounded-none [&_code]:border-0 [&_code]:bg-transparent [&_code]:p-0 [&_code]:text-inherit",
  ),
  code: themed("code", inlineCode),
  table: ({ node: _node, ...props }: ComponentPropsWithoutRef<"table"> & ExtraProps) => (
    <div className="my-[10px] overflow-x-auto">
      <table className="border-collapse text-[12px]" {...props} />
    </div>
  ),
  th: themed(
    "th",
    "border border-line bg-[#101315] px-[9px] py-[5px] text-left font-semibold text-ink",
  ),
  td: themed("td", "border border-line-soft px-[9px] py-[5px] align-top"),
};

/** Renders trusted-source markdown with the workspace chat theme. Raw HTML in
 * the source is not rendered (react-markdown default), so model or user
 * content cannot inject markup. */
export function Markdown({ text }: { text: string }) {
  return (
    <div className="[&>*:first-child]:mt-0 [&>*:last-child]:mb-0">
      <ReactMarkdown remarkPlugins={remarkPlugins} components={components}>
        {text}
      </ReactMarkdown>
    </div>
  );
}
