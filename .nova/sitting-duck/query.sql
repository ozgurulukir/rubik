.mode json
LOAD sitting_duck;
SELECT node_id, type, file_path, name, start_line, end_line
FROM read_ast('lib/rubik/buffer.rb')
WHERE (type LIKE '%function%'
    OR type LIKE '%method%'
    OR type LIKE '%class%'
    OR type LIKE '%def%')
ORDER BY file_path, start_line
LIMIT 20;
