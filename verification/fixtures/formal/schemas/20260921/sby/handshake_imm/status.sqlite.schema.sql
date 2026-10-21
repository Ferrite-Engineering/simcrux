CREATE TABLE task (
    id INTEGER PRIMARY KEY,
    workdir TEXT,
    name TEXT,
    mode TEXT,
    created REAL
);
CREATE TABLE task_property (
    id INTEGER PRIMARY KEY,
    task INTEGER,
    src TEXT,
    name TEXT,
    hdlname TEXT,
    kind TEXT,
    created REAL,
    FOREIGN KEY(task) REFERENCES task(id)
);
CREATE TABLE task_property_status (
    id INTEGER PRIMARY KEY,
    task_property INTEGER,
    task_trace INTEGER,
    status TEXT,
    data TEXT,
    created REAL,
    FOREIGN KEY(task_property) REFERENCES task_property(id),
    FOREIGN KEY(task_trace) REFERENCES task_trace(id)
);
CREATE TABLE task_status (
    id INTEGER PRIMARY KEY,
    task INTEGER,
    status TEXT,
    data TEXT,
    created REAL,
    FOREIGN KEY(task) REFERENCES task(id)
);
CREATE TABLE task_trace (
    id INTEGER PRIMARY KEY,
    task INTEGER,
    trace TEXT,
    path TEXT,
    kind TEXT,
    engine_case TEXT,
    created REAL,
    FOREIGN KEY(task) REFERENCES task(id)
);
-- PRAGMA user_version = 0
