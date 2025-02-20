import argparse
import os

import generate as g

# checks if the docs folder is up to date with the source readme.md files
if __name__ == "__main__":
    arg_parser = argparse.ArgumentParser()
    arg_parser.add_argument("src_dir")
    args = arg_parser.parse_args()

    exclude_dirs = [
        args.src_dir + "docs", # dont search yourself
        args.src_dir + "data", # this should only include data
    ]

    code_path = os.path.join(args.src_dir, "docs/docusaurus/docs/code")
    for name, src_path in g.get_markdown_files(args.src_dir, exclude_dirs):
        docs_path = os.path.join(code_path, name + ".md")

        # check to see if the files are the same !
        with open(src_path, "r") as src_f:
            with open(docs_path, "r") as docs_f:
                src_lines = src_f.readlines()
                # fix image paths for docusaurus
                for i in range(0, len(src_lines)):
                    if "/docs/docusaurus/static/img" in src_lines[i]:
                        src_lines[i] = src_lines[i].replace("/docs/docusaurus/static/img", "/img")

                docs_lines = docs_f.readlines()
                if src_lines != docs_lines:
                    print("Docs folder is not up to date, run generate.py")
                    # print the the first difference
                    for i in range(len(src_lines)):
                        if src_lines[i] != docs_lines[i]:
                            print("Difference found at line", i)
                            print("Source:", src_lines[i])
                            print("Docs:", docs_lines[i])
                            break
                    exit(1)
