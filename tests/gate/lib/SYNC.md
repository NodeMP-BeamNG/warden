# Vendored test helpers

`wire.py`, `wire_taxonomy.py` and `testclient.py` are byte-identical copies of
`server/run/` in `NodeMP-BeamNG/server` at

    main = 08685d4061a843bb6921310bfcbef06b2ec1132b  (build: v1.4.0/1.4.1, protocol v22, ABI 2.3)

    run/wire.py           blob 6743536c7d618d94b01320fc8481b3e85df93b9a
    run/wire_taxonomy.py  blob 1c7606bb90bc3dc054dab4705c57d3fed46a5792
    run/testclient.py     blob 9fb4eef21a384697fab49a537a28902698c1a613

`wire_taxonomy.py` is the generated protocol taxonomy `wire.py` imports, so it
travels with it.

To resync after a server release:

    for f in wire.py wire_taxonomy.py testclient.py; do
      git -C ../server show main:run/$f > tests/gate/lib/$f
    done

and update the commit and blob ids above (`git -C ../server rev-parse main:run/wire.py`).
Never edit the three vendored files here; a fix belongs in the server repository.
