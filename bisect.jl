using Downloads, CodecZlib, Tar, LibGit2

function bisect(bisect_command, start_sha, end_sha, os="linux", arch="x86_64")
    dir = mktempdir()
    cd(dir)
    repo = LibGit2.clone("https://github.com/JuliaLang/julia.git", dir)

    # Get the start and end commit objects
    start_commit = LibGit2.GitCommit(repo, start_sha)
    end_commit = LibGit2.GitCommit(repo, end_sha)

    # Get the commit range
    commit_range::Vector{String} = LibGit2.with(LibGit2.GitRevWalker(repo)) do walker
        LibGit2.map((oid, repo)->string(oid), walker; range=string(LibGit2.GitHash(start_commit))*".."*string(LibGit2.GitHash(end_commit)), by=LibGit2.Consts.SORT_REVERSE)
    end

    # Test script, makes it easy to run bisect command
    file = mktemp()
    write(file[1], bisect_command)

    left = 1
    right = length(commit_range)
    i = 0
    while left < right
        i = (left + right) ÷ 2
        commit = commit_range[i]

        version_full = read(`contrib/commit-name.sh $commit`, String)
        # version_full = run(`powershell -Command $dir/contrib/commit-name.sh $commit`)
        major_minor_version = split(version_full, '.')[1:2] |> x->join(x, '.')

        binary_url = "https://julialangnightlies-s3.julialang.org/bin/$os/$arch/$major_minor_version/julia-$(commit[1:10])-$os-$arch.tar.gz"
        download_path = Downloads.download(binary_url)

        result = mktempdir() do binary_dir
            # extract
            open(download_path) do io
                stream = GzipDecompressorStream(io)
                Tar.extract(stream, binary_dir)
            end

            run(Cmd(
                `$binary_dir/julia-$(commit[1:10])/bin/julia --project=$binary_dir -E include\(\"$(file[1])\"\)`,
                ignorestatus = true
            ))
        end

        println("Commit $commit" * (result.exitcode == 0 ? "suceeded" : "failed"))

        if result.exitcode == 0
            left = i + 1
        else
            right = i
        end
    end

    return left, commit_range[left]
end

using HTTP, JSON3

function get_binaryurl(sha)
    url = "https://buildkite.com/julialang/julia-master/builds?commit=$sha"

    r = HTTP.get(url)
    html = String(r.body)

    build_url = "https://buildkite.com/" * match(r"julialang/julia-master/builds/\d+", html).match * "/waterfall"
    build_num = match(r"julialang/julia-master/builds/(\d+)", html).captures[1]
    r = HTTP.get(build_url)
    html = String(r.body)

    job_url = match(Regex("""href="(.+)"><span title=":linux: build x86_64-linux-gnu">"""), html).captures[1]
    job = split(job_url, '#')[2]

    artifacts_url = "https://buildkite.com/organizations/julialang/pipelines/julia-master/builds/$build_num/jobs/$job/artifacts"
    return "https://buildkite.com/" * (HTTP.get(artifacts_url).body |> JSON3.read)[1].url

    # w = Window()
    # Blink.AtomShell.@dot w loadURL($job_url, Dict(userAgent=>"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.102 Safari/537.36 Edge/18.19582"))
    # # loadurl(w, job_url)
    # # sleep(1)
    # @js w document.getElementById("job-018d3d5b-2238-43eb-9d94-f4553ba0f4f5").querySelectorAll(".btn")[1].click()
    # html = @js w document.querySelector("body").innerHTML

    # match(Regex("""href="(.+)" title="julia-$(sha[1:10])-$os-$arch.tar.gz"""), html)
end

function run_commit(file, commit, os, arch)
    @assert os == "linux"

    version_full = read(`contrib/commit-name.sh $commit`, String)
    major_minor_version = split(version_full, '.')[1:2] |> x->join(x, '.')

    binary_url = "https://julialangnightlies-s3.julialang.org/bin/$os/$arch/$major_minor_version/julia-$(commit[1:10])-$os-$arch.tar.gz"
    download_path = Downloads.download(binary_url)

    result = mktempdir() do binary_dir
        # extract
        open(download_path) do io
            stream = GzipDecompressorStream(io)
            Tar.extract(stream, binary_dir)
        end

        read(Cmd(
            `$binary_dir/julia-$(commit[1:10])/bin/julia --project=$binary_dir -E include\(\"$(file[1])\"\)`,
            ignorestatus=true
            ), String
        )
    end

    parse(Float64, result)
end

function bisect_perf(bisect_command, start_sha, end_sha; factor=1.5, os="linux", arch="x86_64", julia_repo=nothing)
    repo = nothing
    if isnothing(julia_repo)
        dir = mktempdir()
        LibGit2.clone("https://github.com/JuliaLang/julia.git", dir)
        julia_repo = dir
    end
    repo = LibGit2.GitRepo(julia_repo)
    cd(julia_repo)

    # Get the start and end commit objects
    start_commit = LibGit2.GitCommit(repo, start_sha)
    end_commit = LibGit2.GitCommit(repo, end_sha)

    # Get the commit range
    commit_range::Vector{String} = LibGit2.with(LibGit2.GitRevWalker(repo)) do walker
        LibGit2.map((oid, repo)->string(oid), walker; range=string(LibGit2.GitHash(start_commit))*".."*string(LibGit2.GitHash(end_commit)), by=LibGit2.Consts.SORT_REVERSE)
    end
    pushfirst!(commit_range, start_sha)

    # Test script, makes it easy to run bisect command
    file = mktemp()
    write(file[1], bisect_command)

    original_time = run_commit(file, start_sha, os, arch)
    println("Starting commit took $original_time")

    end_time = run_commit(file, end_sha, os, arch)
    println("End commit took $end_time")

    if end_time <= factor * original_time
        return
    end

    failed_commits = String[]

    left = 2
    right = length(commit_range)
    i = 0
    while left < right
        i = (left + right) ÷ 2
        commit = commit_range[i]

        result = try
            run_commit(file, commit, os, arch)
        catch
            push!(failed_commits, commit)
            deleteat!(commit_range, i)
            right = right - 1
            continue
        end

        println("Commit $commit " * ((result <= factor * original_time) ? "succeeded" : "failed") * " in $result")

        if result <= factor * original_time
            left = i + 1
        else
            right = i
        end
    end

    return commit_range[left], failed_commits
end

bisect_command = raw"""
redirect_stdout(open("nul", "w"))
using Pkg
Pkg.add(url="https://github.com/JuliaCI/BaseBenchmarks.jl")
Pkg.add("BenchmarkTools")
using BaseBenchmarks, BenchmarkTools

#BaseBenchmarks.load!("simd")
#results = BaseBenchmarks.SUITE[@tagged "Cartesian" && "conditional_loop!" && 2 && 31 && Int32] |> run |> minimum |> BenchmarkTools.leaves

BaseBenchmarks.load!("array")
results = BaseBenchmarks.SUITE[@tagged "sumelt_boundscheck" && "BaseBenchmarks.ArrayBenchmarks.ArrayLF{Int32, 2}"] |> run |> minimum |> BenchmarkTools.leaves

results[1][2].time
"""
bisect_perf(bisect_command, "e280387cf0811de7541220d8772281f3a86f4c6e", "79de5f3caa4b013f089bd668ea7125c3ab9f39f2"; julia_repo=homedir()*"/Documents/Code/julia-master")