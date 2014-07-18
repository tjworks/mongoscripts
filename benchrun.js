bendb.foo.drop();
db.foo.insert( { _id : 1 } )
 
ops = [{op: "findOne", ns: "test.foo", query: {_id: 1}},
       {op: "update", ns: "test.foo", query: {_id: 1}, update: {$inc: {x: 1}}}]
 
for ( var x = 1; x <= 128; x *= 2) {
    res = benchRun( {
        parallel : x ,
        seconds : 5 ,
        ops : ops
    } );
    print( "threads: " + x + "\t queries/sec: " + res.query );
}