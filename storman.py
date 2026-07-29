# 1. Install uv.
#   powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
# 2. Add dependencies.
#   uv add playwright "invisible_playwright @ git+https://github.com/feder-cr/invisible_playwright.git"
# 3. Run the script.
#   uv run storman.py

import argparse
import collections
import csv
import dataclasses
import datetime
import os
import posixpath
import random
import signal
import sqlite3
import sys
import threading
import typing
import urllib.parse

import invisible_playwright
import playwright.sync_api


@dataclasses.dataclass
class SharePointFile:
    crawl_date: datetime.datetime = datetime.datetime.fromtimestamp(
        0, datetime.timezone.utc
    )
    storman_url: str = ""
    path: str = ""
    depth: int = 0
    large_ancestor_details: str = ""
    type: str = ""
    name: str = ""
    total_size: str = ""
    percentage_of_parent: str = ""
    percentage_of_site_quota: str = ""
    last_modified: str = ""
    details: str = ""


def write_row(
    csv_writer, sqlite_connection: sqlite3.Connection | None, file: SharePointFile
) -> None:
    "Writes a file out as a CSV row and, if configured, to SQLite."
    type: str = file.type.lower()
    if "web" in type:
        type = "Web"
    elif "folder" in type:
        type = "Folder"
    elif "file" in type:
        type = "File"
    row = (
        file.crawl_date.strftime("%Y-%m-%d %H:%M:%S"),
        file.path,
        type,
        file.name,
        file.total_size,
        file.percentage_of_parent,
        file.percentage_of_site_quota,
        file.last_modified,
        file.details,
    )
    if csv_writer is not None:
        csv_writer.writerow(row)
    if sqlite_connection is not None:
        sqlite_connection.execute(
            "INSERT INTO storman (crawl_date, path, type, name, total_size, percentage_of_parent, percentage_of_site_quota, last_modified, details) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING",
            row,
        )
        sqlite_connection.commit()


def parse_size(size: str) -> int:
    "Parses a human readable data size and returns the number of bytes."
    units = {
        "B": 1,
        "KB": 10**3,
        "MB": 10**6,
        "GB": 10**9,
        "TB": 10**12,
        "PB": 10**15,
        "EB": 10**18,
    }
    segments = size.replace("<", "").replace(",", "").strip().split(" ", 1)
    if len(segments) == 1:
        return round(float(segments[0]))
    return int(float(segments[0]) * units[segments[1].strip()])


class Cell(typing.TypedDict):
    href: str | None
    alt_text: str | None
    text_content: str


class DiscardWriter:
    def write(self, text: str) -> int:
        return len(text)


@dataclasses.dataclass
class Args(argparse.Namespace):
    browser: str = ""
    headless: bool = False
    tenant: str = ""
    site: str = ""
    invisible_playwright: bool = False
    delay_min: float = 0
    delay_max: float = 0
    above_percentage_of_site_quota: float = 0.0
    above_size_bytes: int = 0
    max_depth: int = 0
    no_stdout: bool = False
    no_stderr: bool = False
    sqlite_path: str = ""


# Parse arguments.
parser = argparse.ArgumentParser()
parser.add_argument(
    "--browser",
    choices=("chrome", "firefox"),
    default="chrome",
    help="Which browser to use for web scraping. Default is chrome.",
)
parser.add_argument(
    "--headless",
    action="store_true",
    default=False,
    help="Run the browser in headless mode. Default mode is GUI mode.",
)
parser.add_argument("--tenant", type=str, default="", help="SharePoint tenant name.")
parser.add_argument("--site", type=str, default="", help="SharePoint site name.")
parser.add_argument(
    "--invisible-playwright",
    action="store_true",
    default=False,
    help="Whether to use invisible_playwright instead of playwright for web scraping. invisible_playwright is a more stealth-focused web scraping library that uses a patched version of firefox to avoid leaking hints that we are operating a web scraper. Likely not needed for SharePoint unless we start getting blocked.",
)
parser.add_argument(
    "--delay-min",
    type=float,
    default=2.0,
    help="The mininimum duration (in seconds) to wait before navigating to a page (to avoid getting rate-limited). Default is to wait longer than 2.0 seconds.",
)
parser.add_argument(
    "--delay-max",
    type=float,
    default=4.0,
    help="The maximum duration (in seconds) to wait before navigating to a page (to avoid getting rate-limited). Default is to wait up to 4.0 seconds.",
)
parser.add_argument(
    "--above-percentage-of-site-quota",
    type=float,
    default=5.0,
    help="Inside a parent folder, only look at children that are above this percentage of site quota threshold. Default threshold is 5.0%%. If there are no children above this percentage, then all children will be scraped.",
)
parser.add_argument(
    "--above-size-bytes",
    type=int,
    default=1_000_000,
    help="Only scrape files and folders that are above this size in bytes. Default is 1_000_000 (1 MB).",
)
parser.add_argument(
    "--max-depth",
    type=int,
    default=0,
    help="If greater than 0, recurse into folders up to this maximum depth. Default is 0 (unlimited depth).",
)
parser.add_argument(
    "--no-stdout",
    action="store_true",
    default=False,
    help="Suppress printing to stdout. Default is False.",
)
parser.add_argument(
    "--no-stderr",
    action="store_true",
    default=False,
    help="Suppress printing to stderr. Default is False.",
)
parser.add_argument(
    "--sqlite-path",
    type=str,
    default="",
    help="File path of the sqlite3 database to insert rows into. If blank, no rows are inserted. Default is blank (sqlite is not used).",
)
args = Args(**vars(parser.parse_args()))

# Validate arguments.
if args.tenant == "" or args.site == "":
    print("both --tenant and --site must be provided", file=sys.stderr)
    raise SystemExit(1)
if args.delay_min < 0 or args.delay_max < args.delay_min:
    print(
        "--delay-min must be non-negative and no greater than --delay-max",
        file=sys.stderr,
    )
    raise SystemExit(1)


def main(browser_context: playwright.sync_api.BrowserContext) -> None:
    # cancel_event tracks if the user pressed CTRL+C or if the browser was
    # closed.
    cancel_event = threading.Event()
    signal.signal(signal.SIGINT, lambda signum, handler: cancel_event.set())
    browser_context.on("close", lambda browser_context: cancel_event.set())

    # page is the browser tab we are using to navigate the SharePoint site.
    page: playwright.sync_api.Page | None = None

    # queue tracks the storman urls we have yet to crawl. We are crawling with
    # breadth-first search, so priority is given to ancestors first and less
    # priority to later descendants. The idea is we scrape the size of the
    # top-level folders first and later find out the size of sub level folders,
    # so even if the crawl job gets interrupted we still have a good idea of
    # which folders take most space.
    root_folder = SharePointFile(
        storman_url=f"https://{args.tenant}.sharepoint.com/sites/{args.site}/_layouts/15/storman.aspx?root=&OrderBy=0&Asc=0&Page=0",
        path="",
    )
    folder_queue: collections.deque[SharePointFile] = collections.deque([root_folder])

    # Track the paths we've seen. Paths look like "tvcteam" or
    # "financeteam/sglogistics".
    seen_paths: set[str] = set()

    sqlite_connection: sqlite3.Connection | None = None
    if args.sqlite_path != "":
        sqlite_connection = sqlite3.connect(os.path.expanduser(args.sqlite_path), autocommit=True)
        sqlite_connection.execute(
            "CREATE TABLE IF NOT EXISTS storman (crawl_date, path, type, name, total_size, percentage_of_parent, percentage_of_site_quota, last_modified, details, PRIMARY KEY (crawl_date, path))"
        )
        sqlite_connection.execute(
            "CREATE INDEX IF NOT EXISTS storman_path_idx ON storman (path)"
        )
        sqlite_connection.execute(
            "CREATE INDEX IF NOT EXISTS storman_name_idx ON storman (name)"
        )

    # Wrap the main loop in a try so we can silence exceptions due to
    # cancellation (user presses CTRL+C or closes the browser window) but let
    # other exceptions through.
    try:
        # Obtain a new page.
        if len(browser_context.pages) > 0:  # and not args.invisible_playwright:
            page = browser_context.pages[0]
        else:
            page = browser_context.new_page()
        page.on("close", lambda page: cancel_event.set())
        if not args.no_stderr:
            print("page obtained", file=sys.stderr)

        # Prepare the csv writer and write the header row.
        csv_writer = csv.writer(
            sys.stdout if not args.no_stdout else DiscardWriter(), lineterminator="\n"
        )
        csv_writer.writerow(
            (
                "Crawl Date",
                "Root",
                "Type",
                "Name",
                "Total Size",
                "% of Parent",
                "% of Site Quota",
                "Last Modified",
                "Details",
            )
        )

        while len(folder_queue) > 0 and not cancel_event.is_set():
            folder = folder_queue.popleft()

            # If we've seen this path, skip.
            if folder.path in seen_paths:
                continue
            seen_paths.add(folder.path)

            # If this isn't the root path, wait for a random delay (or until
            # the user cancels) before we navigate to a page so we don't hammer
            # the SharePoint site at inhuman speeds and trigger their rate
            # limiter.
            if folder.path != "":
                canceled = cancel_event.wait(
                    random.uniform(args.delay_min, args.delay_max)
                )
                if canceled:
                    break

            # Set the next_url to crawl to the queue item's storman_url.
            next_url = folder.storman_url

            # As long as there is a next_url, crawl it.
            while next_url != "" and not cancel_event.is_set():
                # Visit the page.
                if not args.no_stderr:
                    print(
                        f"{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')} visiting {next_url}",
                        file=sys.stderr,
                    )
                response = page.goto(
                    url=next_url, wait_until="domcontentloaded", timeout=120_000
                )

                # If we are not logged in, ask the user to complete the login
                # flow. A subsequent run will reuse the authenticated
                # persistent browser profile.
                if page.url.startswith("https://login.microsoftonline.com/"):
                    if not args.no_stderr:
                        print("please complete the login flow", file=sys.stderr)
                    if not args.headless:
                        while not cancel_event.is_set() and not page.is_closed():
                            cancel_event.wait(0.25)
                    return

                # If we got an error code when visiting the page, emit an error
                # event and break.
                if response is not None and response.status >= 400:
                    write_row(
                        csv_writer,
                        sqlite_connection,
                        SharePointFile(
                            path=folder.path,
                            details=f"{next_url}: HTTP {response.status}",
                        ),
                    )
                    break

                # Set the next_url back to an empty string so we don't crawl it
                # again.
                next_url = ""

                # The DOM may be loaded before SharePoint makes the results
                # table visible.
                page.locator("#onetidUserRptrTable").wait_for(
                    state="visible", timeout=120_000
                )

                # Extract rows from the table.
                rows = typing.cast(
                    list[list[Cell]],
                    page.locator("#onetidUserRptrTable").evaluate("""function(element) {
                        const rows = [];
                        for (const row of element.rows) {
                            const cells = [];
                            for (const cell of row.cells) {
                                cells.push({
                                    href: cell.querySelector("a")?.href,
                                    alt_text: cell.querySelector("img")?.alt,
                                    text_content: cell.textContent.trim(),
                                });
                            }
                            rows.push(cells);
                        }
                        return rows;
                    }"""),
                )

                # If the table has no rows, break.
                if len(rows) == 0:
                    break

                # The set of columns names we are looking for.
                column_name_set: set[str] = set(
                    [
                        "Type",
                        "Name",
                        "Total Size",
                        "% Of Parent",
                        "% Of Site Quota",
                        "Last Modified",
                    ]
                )

                # indexes maps the column name to the column index in the
                # table.
                indexes: dict[str, int] = {}

                # Walk the header row to find the column indexes of the column
                # names.
                for index, cell in enumerate(rows[0]):
                    column_name = " ".join(cell["text_content"].split()).title()
                    if column_name in column_name_set:
                        indexes[column_name] = index

                # Convert the rows (excluding the header) into a list of files.
                files: list[SharePointFile] = []
                large_files: list[SharePointFile] = []
                for row in rows[1:]:
                    # If the row has no cells, skip.
                    if len(row) == 0:
                        continue

                    # Convert the row into a file.
                    file = SharePointFile(
                        crawl_date=datetime.datetime.now(),
                        storman_url=row[indexes["Name"]]["href"] or "",
                        large_ancestor_details=folder.large_ancestor_details,
                        type=row[indexes["Type"]]["alt_text"] or "",
                        name=row[indexes["Name"]]["text_content"],
                        total_size=row[indexes["Total Size"]]["text_content"],
                        percentage_of_parent=row[indexes["% Of Parent"]][
                            "text_content"
                        ],
                        percentage_of_site_quota=row[indexes["% Of Site Quota"]][
                            "text_content"
                        ],
                        last_modified=row[indexes["Last Modified"]]["text_content"],
                    )
                    if "folder" in file.type.lower() or "file" in file.type.lower():
                        file.depth = folder.depth + 1
                    else:
                        file.depth = folder.depth

                    # Get the path. If it's a folder, the path is in
                    # storman_url. If it's a file, the path is the parent
                    # folder path joined with the file name.
                    if file.storman_url != "":
                        split_result = urllib.parse.urlsplit(file.storman_url)
                        query_params = urllib.parse.parse_qs(split_result.query)
                        if "root" in query_params:
                            if len(query_params["root"]) > 0:
                                file.path = query_params["root"][0]
                    else:
                        file.path = posixpath.join(folder.path, file.name.lstrip("/"))

                    # If file.percentage_of_site_quota exceeds the threshold,
                    # append it to the list of large files. Sometimes the
                    # string is "Not Available" instead of a valid number, so
                    # catch any ValueError arising from trying to parse an
                    # invalid string as float.
                    try:
                        if (
                            float(file.percentage_of_site_quota.removesuffix("%"))
                            >= args.above_percentage_of_site_quota
                        ):
                            large_files.append(file)
                    except ValueError:
                        pass

                    # Append the file into the list of files.
                    files.append(file)

                if folder.large_ancestor_details != "":
                    for file in files:
                        try:
                            if parse_size(file.total_size) <= 1_000_000:
                                continue
                        except ValueError:
                            continue
                        file.details = folder.large_ancestor_details
                        write_row(csv_writer, sqlite_connection, file)
                        if file.storman_url != "" and (
                            args.max_depth <= 0 or file.depth < args.max_depth
                        ):
                            folder_queue.append(file)
                        locator = page.locator("a:has(img[alt=Next])")
                        if locator.count() > 0:
                            next_url = urllib.parse.urljoin(
                                page.url, locator.first.get_attribute("href") or ""
                            )
                else:
                    if len(large_files) > 0:
                        for file in large_files:
                            try:
                                if parse_size(file.total_size) <= 1_000_000:
                                    continue
                            except ValueError:
                                continue
                            file.details = f"{file.path}: percentage_of_site_quota {file.percentage_of_site_quota} ({file.total_size}) is above {args.above_percentage_of_site_quota}%"
                            write_row(csv_writer, sqlite_connection, file)
                            if file.storman_url != "" and (
                                args.max_depth <= 0 or file.depth < args.max_depth
                            ):
                                folder_queue.append(file)
                            if len(large_files) == len(files):
                                locator = page.locator("a:has(img[alt=Next])")
                                if locator.count() > 0:
                                    next_url = urllib.parse.urljoin(
                                        page.url,
                                        locator.first.get_attribute("href") or "",
                                    )
                    else:
                        for file in files:
                            try:
                                if parse_size(file.total_size) <= 1_000_000:
                                    continue
                            except ValueError:
                                continue
                            file.details = f"belongs to large ancestor: {folder.path} ({folder.total_size}, {folder.percentage_of_site_quota})"
                            file.large_ancestor_details = file.details
                            write_row(csv_writer, sqlite_connection, file)
                            if file.storman_url != "" and (
                                args.max_depth <= 0 or file.depth < args.max_depth
                            ):
                                folder_queue.append(file)
                            locator = page.locator("a:has(img[alt=Next])")
                            if locator.count() > 0:
                                next_url = urllib.parse.urljoin(
                                    page.url, locator.first.get_attribute("href") or ""
                                )

    except Exception:
        if not cancel_event.is_set() and (page is None or not page.is_closed()):
            raise
    finally:
        if sqlite_connection is not None:
            sqlite_connection.commit()
            sqlite_connection.close()


if __name__ == "__main__":
    if args.invisible_playwright:
        with invisible_playwright.InvisiblePlaywright(
            profile_dir=os.path.expanduser("~/Documents/FirefoxProfile"),
            headless=args.headless,
        ) as browser_context:
            main(typing.cast(playwright.sync_api.BrowserContext, browser_context))
    else:
        with playwright.sync_api.sync_playwright() as sync_playwright:
            browser_context = (
                sync_playwright.firefox
                if args.browser == "firefox"
                else sync_playwright.chromium
            ).launch_persistent_context(
                user_data_dir=os.path.expanduser(
                    "~/Documents/FirefoxProfile"
                    if args.browser == "firefox"
                    else "~/Documents/ChromeProfile"
                ),
                channel=None if args.browser == "firefox" else "chrome",
                chromium_sandbox=args.browser == "chrome",
                headless=args.headless,
                ignore_default_args=None
                if args.browser == "firefox"
                else ["--disable-extensions", "--enable-automation"],
                no_viewport=True,
            )
            main(browser_context)
