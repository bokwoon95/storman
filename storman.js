"use strict";

document.addEventListener("DOMContentLoaded", async function main() {
  const status = document.querySelector("#status");
  const sqliteWasmBytes = Uint8Array.from(
    atob(document.getElementById("sqlite-3.53.4.wasm").textContent.replace(/\s/g, "")),
    (character) => character.charCodeAt(0)
  );
  let sqlite3;
  try {
    sqlite3 = await globalThis.sqlite3InitModule({
      instantiateWasm(imports, success) {
        const module = new WebAssembly.Module(sqliteWasmBytes);
        const instance = new WebAssembly.Instance(module, imports);
        success(instance, module);
        return instance.exports;
      }
    });
  } catch (error) {
    status.classList.add("error");
    status.textContent = error.message;
    console.error(error);
    return;
  }

  const results = document.querySelector("#results");
  const databaseFile = document.querySelector("#database-file");
  const tableSearch = document.querySelector("#table-search");
  const chartElement = document.querySelector("#chart");
  const chart = echarts.init(chartElement);
  const selectedNodes = new Map();
  const uncheckAll = document.querySelector("#uncheck-all");
  let databaseLoaded = false;
  chart.setOption({
    animation: false,
    title: {
      text: "Click here to choose a file, or drag and drop in a file",
      left: "center",
      top: "middle",
      textStyle: { color: "#888", fontSize: 16, fontWeight: "normal" }
    },
    tooltip: {
      trigger: "axis",
      valueFormatter(value) {
        const unitIndex = value === 0
          ? 0
          : Math.min(Math.floor(Math.log(Math.abs(value)) / Math.log(1000)), 6);
        return `${unitIndex === 0 ? value : (value / 1000 ** unitIndex).toFixed(1)} ${[
          "B",
          "KB",
          "MB",
          "GB",
          "TB",
          "PB",
          "EB"
        ][unitIndex]}`;
      }
    },
    legend: { type: "scroll", left: 55, right: 20, top: 10 },
    grid: { left: 75, right: 30, top: 55, bottom: 55 },
    xAxis: { type: "time", name: "Time", nameLocation: "middle", nameGap: 30 },
    yAxis: {
      type: "value",
      name: "Size",
      scale: true,
      axisLabel: {
        formatter(value) {
          const unitIndex = value === 0
            ? 0
            : Math.min(
              Math.floor(Math.log(Math.abs(value)) / Math.log(1000)),
              6
            );
          return `${unitIndex === 0 ? value : (value / 1000 ** unitIndex).toFixed(1)}${[
            "B",
            "K",
            "M",
            "G",
            "T",
            "P",
            "E"
          ][unitIndex]}`;
        }
      }
    },
    series: []
  });
  new ResizeObserver(() => chart.resize()).observe(chartElement);
  const drawSelectedNodes = () => {
    const relative =
      document.querySelector('input[name="chart-scale"]:checked').value ===
      "relative";
    chart.setOption({
      title: {
        show: selectedNodes.size === 0,
        text: databaseLoaded
          ? "Select a file or folder to graph"
          : "Click here to choose a file, or drag and drop in a file"
      },
      legend: { data: [...selectedNodes.keys()] },
      yAxis: { name: relative ? "Change in size" : "Size" },
      series: [...selectedNodes.values()].map((selectedNode) => ({
        name: selectedNode.path,
        type: "line",
        showSymbol: selectedNode.xy.length < 50,
        connectNulls: false,
        data: selectedNode.xy.map(([timestamp, size]) => [
          timestamp * 1000,
          relative ? size - selectedNode.xy[0][1] : size
        ])
      }))
    }, { replaceMerge: ["series"] });
    chartElement.classList.toggle(
      "database-drop-target",
      !databaseLoaded && selectedNodes.size === 0
    );
    uncheckAll.disabled = selectedNodes.size === 0;
  };
  document.querySelector(".chart-controls").addEventListener("change", (event) => {
    if (event.target.name === "chart-scale") drawSelectedNodes();
  });

  const displayDatabase = (arrayBuffer, source) => {
    const bytes = new Uint8Array(arrayBuffer);
    const pointer = sqlite3.wasm.allocFromTypedArray(bytes);
    const database = new sqlite3.oo1.DB();

    try {
      database.checkRc(sqlite3.capi.sqlite3_deserialize(
        database.pointer,
        "main",
        pointer,
        bytes.byteLength,
        bytes.byteLength,
        sqlite3.capi.SQLITE_DESERIALIZE_FREEONCLOSE
      ));

      const columnNames = [];
      const rows = [];
      database.exec({
        sql: `
          SELECT
            crawl_date,
            name,
            path,
            total_size,
            percentage_of_site_quota,
            last_modified,
            type,
            details
          FROM storman
          ORDER BY crawl_date DESC, path
        `,
        columnNames,
        rowMode: "array",
        resultRows: rows
      });

      const paths = [];
      database.exec({
        sql: `
          SELECT
            path,
            type,
            percentage_of_site_quota,
            total_size,
            unixepoch(crawl_date)
          FROM storman
          WHERE path IS NOT NULL
            AND path <> ''
          ORDER BY path, crawl_date DESC
        `,
        rowMode: "array",
        resultRows: paths
      });

      const treeData = [];
      const nodes = new Set();
      const siblingGroups = new Set([treeData]);
      for (const [
        path,
        type,
        percentageOfSiteQuota,
        totalSize,
        crawlDate
      ] of paths) {
        const parts = path.split("/").filter(Boolean);
        let children = treeData;
        for (let index = 0; index < parts.length; index++) {
          let node = children.find((item) => item.name === parts[index]);
          if (!node) {
            const isFile = index === parts.length - 1 && type === "File";
            node = {
              name: parts[index],
              type: isFile ? "file" : "folder",
              xy: []
            };
            nodes.add(node);
            if (!isFile) {
              node.children = [];
              node.open = false;
              siblingGroups.add(node.children);
            }
            children.push(node);
          }
          node.path = parts.slice(0, index + 1).join("/");
          if (index === parts.length - 1) {
            node.stormanType = type;
            node.percentageOfSiteQuota =
              Number.parseFloat(String(percentageOfSiteQuota).replace(/%$/, "")) || 0;
            const [value, unit = "B"] = String(totalSize)
              .replace(/[<,]/g, "")
              .trim()
              .split(/\s+/, 2);
            const size = Number.parseFloat(value);
            const multiplier = {
              B: 1,
              KB: 10 ** 3,
              MB: 10 ** 6,
              GB: 10 ** 9,
              TB: 10 ** 12,
              PB: 10 ** 15,
              EB: 10 ** 18
            }[unit];
            node.totalSize =
              Number.isFinite(size) && multiplier !== undefined
                ? size * multiplier
                : 0;
            if (
              Number.isFinite(size) &&
              multiplier !== undefined &&
              Number.isInteger(crawlDate)
            ) {
              node.xy.push([crawlDate, node.totalSize]);
            }
          }
          if (node.children) children = node.children;
        }
      }
      for (const node of nodes) {
        node.xy.sort(([leftTimestamp], [rightTimestamp]) =>
          leftTimestamp - rightTimestamp
        );
        if (node.xy.length > 0) node.totalSize = node.xy.at(-1)[1];
        node.gradient = 0;
        node.percentageChange = 0;
        if (node.xy.length > 1) {
          const meanX =
            node.xy.reduce((sum, [x]) => sum + x, 0) / node.xy.length;
          const meanY =
            node.xy.reduce((sum, [, y]) => sum + y, 0) / node.xy.length;
          let numerator = 0;
          let denominator = 0;
          for (const [x, y] of node.xy) {
            numerator += (x - meanX) * (y - meanY);
            denominator += (x - meanX) ** 2;
          }
          if (denominator !== 0) {
            node.gradient = numerator / denominator;
            const fittedFirstSize =
              meanY + node.gradient * (node.xy[0][0] - meanX);
            const fittedLastSize =
              meanY + node.gradient * (node.xy.at(-1)[0] - meanX);
            if (fittedFirstSize !== 0) {
              node.percentageChange =
                (fittedLastSize - fittedFirstSize) /
                Math.abs(fittedFirstSize) *
                100;
            }
          }
        }
      }
      for (const siblings of siblingGroups) {
        siblings.sort((left, right) =>
          right.percentageOfSiteQuota - left.percentageOfSiteQuota ||
          right.totalSize - left.totalSize ||
          left.name.localeCompare(right.name)
        );
      }

      const fileTree = document.querySelector("#file-tree");
      fileTree.replaceChildren();
      selectedNodes.clear();
      drawSelectedNodes();
      const tree = new Tree(fileTree, { navigate: true });
      let checkboxIndex = 0;
      tree.on("created", (element, node) => {
        const name = element.textContent;
        element.dataset.xy = JSON.stringify(node.xy);
        if (element.tagName === "SUMMARY") {
          element.style.backgroundColor = "transparent";
        }
        const checkbox = document.createElement("input");
        checkbox.type = "checkbox";
        checkbox.id = `tree-node-${++checkboxIndex}`;
        checkbox.style.marginLeft = "0";
        checkbox.addEventListener("click", (event) => event.stopPropagation());
        checkbox.addEventListener("change", () => {
          if (checkbox.checked) {
            selectedNodes.set(node.path, node);
          } else {
            selectedNodes.delete(node.path);
          }
          drawSelectedNodes();
        });
        const label = document.createElement("label");
        label.htmlFor = checkbox.id;
        const totalSize = node.totalSize || 0;
        const unitIndex = totalSize === 0
          ? 0
          : Math.min(
            Math.floor(Math.log(Math.abs(totalSize)) / Math.log(1000)),
            6
          );
        label.textContent = `${{
          Web: "\u{1F310}",
          Folder: "\u{1F4C2}",
          File: "\u{1F4C4}"
        }[node.stormanType || (node.type === "file" ? "File" : "Folder")]} ${name} (${unitIndex === 0 ? totalSize : (totalSize / 1000 ** unitIndex).toFixed(1)} ${[
          "B",
          "KB",
          "MB",
          "GB",
          "TB",
          "PB",
          "EB"
        ][unitIndex]}, ${node.percentageChange > 0 ? "\u{2B06}\u{FE0F}" : node.percentageChange < 0 ? "\u{2B07}\u{FE0F}" : "\u{27A1}\u{FE0F}"}${Math.abs(node.percentageChange).toFixed(1)}%)`;
        label.style.marginLeft = "0";
        label.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          checkbox.click();
        });
        element.replaceChildren(checkbox, label);
        element.addEventListener("dblclick", (event) => {
          if (element.tagName !== "SUMMARY") return;
          event.preventDefault();
          event.stopPropagation();
          element.parentElement.open = !element.parentElement.open;
        });
      });
      tree.json(treeData);

      results.replaceChildren();
      const head = results.createTHead();
      const headingRow = head.insertRow();
      for (const columnName of columnNames.slice(0, 6)) {
        const heading = document.createElement("th");
        heading.scope = "col";
        heading.textContent = columnName;
        headingRow.append(heading);
      }

      const body = results.createTBody();
      for (const row of rows) {
        const tableRow = body.insertRow();
        tableRow.dataset.name = String(row[1] ?? "").toLowerCase();
        tableRow.dataset.path = String(row[2] ?? "").toLowerCase();
        for (let index = 0; index < 6; index++) {
          const value = row[index];
          const cell = tableRow.insertCell();
          if (index === 1) {
            const icon = document.createElement("span");
            icon.textContent = {
              Web: "\u{1F310}",
              Folder: "\u{1F4C2}",
              File: "\u{1F4C4}"
            }[row[6]] || "";
            const nameValue = document.createElement("span");
            nameValue.className = "name-value";
            nameValue.textContent = value ?? "NULL";
            nameValue.title = value ?? "";
            nameValue.addEventListener("dblclick", () => {
              const selection = globalThis.getSelection();
              const range = document.createRange();
              range.selectNodeContents(nameValue);
              selection.removeAllRanges();
              selection.addRange(range);
            });
            const nameContent = document.createElement("span");
            nameContent.className = "name-content";
            nameContent.append(icon, nameValue);
            cell.className = "name-cell";
            cell.append(nameContent);
          } else if (index === 2) {
            const pathValue = document.createElement("span");
            pathValue.className = "path-value";
            pathValue.textContent = value ?? "NULL";
            pathValue.title = value ?? "";
            pathValue.addEventListener("dblclick", () => {
              const selection = globalThis.getSelection();
              const range = document.createRange();
              range.selectNodeContents(pathValue);
              selection.removeAllRanges();
              selection.addRange(range);
            });
            cell.className = "path-cell";
            cell.append(pathValue);
          } else {
            cell.textContent = value instanceof Uint8Array
              ? `[BLOB: ${value.byteLength} bytes]`
              : value === null
                ? "NULL"
                : String(value);
          }
        }
      }
      tableSearch.value = "";
      tableSearch.disabled = false;

      status.classList.remove("error");
      status.textContent = `${rows.length.toLocaleString()} rows from ${source}`;
    } finally {
      database.close();
    }
  };

  tableSearch.addEventListener("input", () => {
    const query = tableSearch.value.trim().toLowerCase();
    for (const row of results.tBodies[0]?.rows || []) {
      row.hidden =
        !row.dataset.name.includes(query) &&
        !row.dataset.path.includes(query);
    }
  });

  uncheckAll.addEventListener("click", () => {
    for (const checkbox of document.querySelectorAll(
      '#file-tree input[type="checkbox"]:checked'
    )) {
      checkbox.checked = false;
    }
    selectedNodes.clear();
    drawSelectedNodes();
  });

  const loadDatabaseFile = async (file) => {
    status.classList.remove("error");
    status.textContent = `Loading ${file.name}…`;
    try {
      displayDatabase(await file.arrayBuffer(), file.name);
      databaseLoaded = true;
    } catch (error) {
      status.classList.add("error");
      status.textContent = error.message;
      console.error(error);
    } finally {
      drawSelectedNodes();
    }
  };

  databaseFile.disabled = false;
  databaseFile.addEventListener("change", async () => {
    if (!databaseFile.files[0]) return;
    await loadDatabaseFile(databaseFile.files[0]);
  });
  chartElement.addEventListener("click", () => {
    if (selectedNodes.size === 0) databaseFile.click();
  });
  chartElement.addEventListener("keydown", (event) => {
    if (
      selectedNodes.size === 0 &&
      (event.key === "Enter" || event.key === " ")
    ) {
      event.preventDefault();
      databaseFile.click();
    }
  });
  chartElement.addEventListener("dragover", (event) => {
    event.preventDefault();
    event.dataTransfer.dropEffect = "copy";
    chartElement.classList.remove("database-drop-target");
    chart.setOption({
      title: { show: true, text: "Drop file here" }
    });
  });
  chartElement.addEventListener("dragleave", (event) => {
    if (!chartElement.contains(event.relatedTarget)) {
      chartElement.classList.toggle(
        "database-drop-target",
        !databaseLoaded && selectedNodes.size === 0
      );
      chart.setOption({
        title: {
          show: selectedNodes.size === 0,
          text: databaseLoaded
            ? "Select a file or folder to graph"
            : "Click here to choose a file, or drag and drop in a file"
        }
      });
    }
  });
  chartElement.addEventListener("drop", async (event) => {
    event.preventDefault();
    chartElement.classList.remove("database-drop-target");
    chart.setOption({
      title: {
        show: selectedNodes.size === 0,
        text: databaseLoaded
          ? "Select a file or folder to graph"
          : "Click here to choose a file, or drag and drop in a file"
      }
    });
    if (event.dataTransfer.files[0]) {
      await loadDatabaseFile(event.dataTransfer.files[0]);
    }
  });

  drawSelectedNodes();
  status.textContent = "SQLite is ready. Load the storman.db file.";
});
