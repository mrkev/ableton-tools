import { useState } from "react";
import GitHubButton from "react-github-btn";
import { add } from "../../NEW_LIB/src";

const FOLDER_STRUCTURE = `
docs/             built website, configure GH Pages to point here
packages/
  NEW_LIB/        source for the library
  site/           source code for the site
`.trim();

export function App() {
  const [count, setCount] = useState(0);

  return (
    <main className="space-y-6">
      <h1 className="text-4xl font-bold m-0 mb-2">
        Simple
        <br />
        Vite + React + TypeScript
        <br />
        Monorepo Library Template
      </h1>

      <p>
        <a href="https://github.com/mrkev/new-react-ts-monorepo-lib">
          github.com/mrkev/new-react-ts-monorepo-lib
        </a>
      </p>

      <span className="flex flex-row gap-2 justify-center">
        <GitHubButton
          href="https://github.com/mrkev/new-react-ts-monorepo-lib"
          data-color-scheme="no-preference: light; light: light; dark: dark;"
          data-icon="octicon-star"
          data-size="large"
          aria-label="Star mrkev/new-react-ts-monorepo-lib on GitHub"
        >
          Star
        </GitHubButton>
        <GitHubButton
          href="https://github.com/mrkev/new-react-ts-monorepo-lib/generate"
          data-color-scheme="no-preference: light; light: light; dark: dark;"
          data-icon="octicon-repo-template"
          data-size="large"
          aria-label="Use this template mrkev/new-react-ts-monorepo-lib on GitHub"
        >
          Use this template
        </GitHubButton>
      </span>

      {/* Instructions */}
      <h2 className="text-left text-2xl font-semibold mb-2">Getting Started</h2>
      <ol className="text-left ps-5 mt-2 space-y-1 list-decimal list-inside">
        <li>
          Click <code>"Use this template"</code> above
        </li>
        <li>Clone the repo you created</li>
        <li>Use these scripts:</li>
        {/* Scripts */}
        <ul className="text-left ps-5 space-y-1 list-disc list-inside">
          <li>
            <code>build</code> builds this website and the library ready for
            publishing
          </li>
          <li>
            <code>build:site</code> builds only the website
          </li>
          <li>
            <code>build:lib</code> builds only the library
          </li>
          <li>
            <code>dev</code> starts the dev server
          </li>
        </ul>
        <li>Edit away! Folder structure:</li>
        <pre className="text-left bg-black text-white py-2 px-4">
          {FOLDER_STRUCTURE}
        </pre>
      </ol>
      <hr />

      <p className="text-left">
        This sample library just adds two numbers.
        <br />
        The latest version is always built with the site:
      </p>
      <button onClick={() => setCount((count) => add(count, 1))}>
        add one: {count}
      </button>

      <hr />

      <p className="flex flex-row gap-2 justify-center">
        <a href="https://aykev.dev/">Kevin Chavez</a> ·
        <a href="https://twitter.com/aykev">@aykev</a> ·
        <GitHubButton
          href="https://github.com/mrkev"
          data-color-scheme="no-preference: light; light: light; dark: dark;"
          data-size="large"
          data-show-count="true"
          aria-label="Follow @mrkev on GitHub"
        >
          Follow @mrkev
        </GitHubButton>
      </p>
    </main>
  );
}
