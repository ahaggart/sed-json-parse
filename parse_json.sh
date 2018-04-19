#! /bin/bash

# retrieve a nested set of braces from a json string -- $1: json string
# sed: [[ 's/.*\("[^"]*"\): *\({[^{}]*}\).*/\1:\2/' ]]
# ---- [[ .* ]] --> all characters before nested brace field
# ---- [[ \({[^{}]*}\) ]] --> leaf braces ie no braces nested inside => end of nesting branch
# ---- [[ .* ]] --> all characters following nested braces
# ---- [[ \1 ]] --> output only leaf brace expression
# ---- greedy matching favors the first [[ .* ]], so the matched expression will be the LATEST in the string
function get_interior () { echo $(echo "$1" | sed  's/.*\({[^{}]*}\).*/\1/'); }

# replace the value of a field with a numbered reference -- $1: json string -- $2: field name -- $3: reference number
# sed: [[ "s/\(.*\"$2\": *\){[^{}]*}\(.*\)/\1#$3\2/" ]]
# ---- [[ \(.*\) ]] --> all characters preceding leaf braces ~~> use greedy parse to ensure matching LATEST
# ---- [[ {[^{}]*} ]] --> leaf braces ie bracket expression containing no further nested braces
# ---- [[ \1#$2 ]] --> replace nested brace value with a numbered reference, leave preceding chars untouched
function replace_interior () { echo $(echo "$1" | sed  "s/\(.*\){[^{}]*}/\1#$2/"); }

function unpack () { # unpack a given json string -- $1: packed base string -- $2...: unrolled json array
	local result="$1"
	# echo "${result:1}"
	# echo "$2"
	local iter=1
	while [[ $iter == 1 ]]; do # iterate until there are no more line references to unpack
		iter=0 # assume we will be done
		# now we need to "re-pack" line references
		local ref=$(echo "$result" | sed 's/.*[:[ ]*\(#[0-9]*\) *[]\,}].*/\1/') # find a line reference in the packed string
		# echo "1: $ref"
		if [ "${ref:0:1}" == "#" ]; then # make sure we actaully found a line reference
			ref="${ref:1}" # extract argument number from line reference
			#echo "2: $ref"
			# str="$(echo ${!ref} | sed 's/"[^"]*":\(.*\)/\1/' | sed 's/|/\\|/g')" # unpack the referenced line and escape any pipe chars
			str="$(echo ${!ref} | sed 's/|/\\|/g')"
			result=$(echo "$result" | sed "s|\([:[ ]*\)*#$ref\( *[]\,}]\)*|\1$str\2|") # re-insert upacked line 
			iter=1 # there might be more referenced in the unpacked line, not done here
		fi
		# echo "2: $result"
	done
	echo "$result"	
}

function get_item () { # fetch an item from a json string -- $1: num lines -- $...2: json lines -- $3 keys
	local keys; local i; local keychain
	((keys=$1+2)) # figure out where the json dictionary keys start
	((i=keys-1)) # first line reference should the end of array (top of stack)
	local str="${!i}" # follow the current line reference
	local i="${str:1}"
	local result="$str"
	local val=""
	for key in "${@:$keys}"; do # iterate over keys, each key should appear in the current line, pointed to by $i
		local str="${!i}" # follow the current line reference
		keychain="$keychain$key --> "
		if [[ "$key" =~ ^[0-9]+$ ]]; then # found an array index -- make sure we have an array
			if ! [[ "$result" =~ ^\[.*\]$ ]]; then # if we have an array, it is loaded in $result
				echo "Error: Indexing into non-array"
				echo "--> in: $result"
				echo "keychain: $keychain [ERROR]"
				exit 1
			fi

			# find a better way to deal with nested arrays -- try character-by-character iteration
			# maybe use the same unroller as the json braces
			# iterate over retrieved string
			local stack_level=0
			local quote_toggle=1
			local arr_index=0
			local index_start=1
			local index_end=0
			#echo "array: $result"
			for (( char_index=0; char_index<${#result}; char_index++ )); do
				local curr_char="${result:$char_index:1}"
				#echo "$curr_char"
				# make this into a case statement?
				if [ "$escape" == "1" ]; then
					: # do nothing, this character is escaped
				elif [ "$curr_char" == '"' ]; then
					((quote_toggle*=-1))
				elif [ "$quote_toggle" == "-1" ]; then
					: # do nothing, we are inside a quote
				elif [ "$stack_level" == "1" ] && [[ "$curr_char" =~ [],] ]]; then
					((arr_index++))
					#echo "$arr_index"
					if [[ "$arr_index" == "$key" ]]; then # we are in the index we want, mark the spot
						((index_start=char_index+1))
						#echo "index_start: $index_start"
					elif [[ "$arr_index" -gt "$key" ]]; then # we have passed the index we want, mark the spot
						((index_end=char_index))
						#echo "index_end: $index_end"
						break
					fi
				elif [ "$curr_char" == "[" ]; then
					((stack_level++))
				elif [ "$curr_char" == "]" ]; then 
					((stack_level--))
				fi
				local escape=0
				if [ "$curr_char" == "\\" ]; then
					escape=1	
				fi		
			done

			val="${result:$index_start:$((index_end-index_start))}" # $((index_end-index_start))
			#echo "$val"
		else
		# echo "i: $i"
		# echo "str: $str"
			val=$(echo "$str" | sed "s/.*\"$key\": *\(.[^{}:]*.\)[\,}].*/\1/") # extract value of key field
		fi
		# echo "$val"
		#val=$(echo "$val" | sed -E '') # remove unquoted stuff
		if [ "${val:0:1}" == "#" ]; then # value is a reference, must be unpacked
			i="${val:1}"
			result="${!i}"
		elif [ "${val: -1}" == '}' ]; then # 'value' ends in bracket, which is impossible for a real val (would be a reference)
			echo "KeyError: \"$key\"" # key field was not found in current layer --> KeyError
			echo "--> [$key] in: $str"
			echo "keychain: $keychain [ERROR]"
			return 1
		else # value is not nested, may not need to unpack
			result="$val"
		fi
	done
	#echo "got here"
	#local result="$(echo "${!i}" | sed 's/^"[^"]*":\(.*\)/\1/')" # extract the result from the final line number
	
	echo $(unpack "$result" "${@:2}") | sed 's/^"\(.*\)"$/\1/' # strip off quotes (if any)
	return 0
}

function load_json () { # unpack json into global array -- $1: file path -- $load_json_out: (global) array output
	# use a stack to organize json
	local raw=$(cat "$1") # pull json string from a file
	local reduced_base="$raw"
	local i="0"

	while [ "$base" != "$reduced_base" ]; do # reduce string until no reductions are made
		local base="$reduced_base"
		local interior=$(get_interior "$base") # retrieve a non-nesting bracketed expression
		#echo "0: $base"
		#echo "1: $interior"
		load_json_out[$i]="$interior" # retrieved expression in next array entry
		#echo "$interior" >> "test_out.txt"
		#echo "2: $interior"
		reduced_base=$(replace_interior "$base" "$((i+2))") # replace value of parsed field name with reference
		#echo "3: $reduced_base"
		((i++)) # increment array index
	done

}

function write_json_stack () { # write a generated json stack to a file -- $1: file path -- $2...: array entries
	local i="2"
	#echo "SOURCE JSON -- $(get_item "$(($#-1))" "${@:2}")" > "$1" # fully unpack the json array to recover "source"
	echo "SOURCE JSON -- $(unpack "${@: -1}" "${@:2}")" > "$1" # fully unpack the json array to recover "source"
	# echo "${@: -1}"
	# echo "${@:2}"
	while [[ $i -lt $# ]]; do
		echo "${!i}" >> "$1"
		((i++))
	done
	echo "${!i}" >> "$1"
}

function run (){
	echo; echo; echo
	echo -n > "test_out.txt"
	load_json "$1"

	test_stack=("${load_json_out[@]}")

	# echo "${test_stack[@]}"

	write_json_stack "test_out.txt" "${test_stack[@]}"

	get_item "${#test_stack[@]}" "${test_stack[@]}" "${@:2}"
}

# run "$@"

# SECOND GEN JSON PARSER -- mass extraction and substitution speeds up large string processing

# return all leaf brace expressions
function get_nested () { echo "$1" | grep -o -E '(\{[^][{}]*\}|\[[^][{}]*\])' | sed "s/ /\\ /g"; }

# replace all leaf brace expressions with a batch number
function replace_nested () { echo $(echo "$1" | sed -E "s/\{[^][{}]*\}|\[[^][{}]*\]/#$2/g"); }

function repack_nested () { # repack line references -- $1: string to repack -- $...2: unpacked array
	local new_base="$1"
	local newline=$'\n'
	SAVE_IFS="$IFS"
	IFS="$newline"
	# repack until there are no references to repack --> repacker will not make any changes to base
	while ! [ "$new_base" == "$base" ]; do 
		local base="$new_base"
		local refs=($(echo "$base" | grep -o -E "(#[0-9]+)" | sed 's/.*#//')) # unpack line references into array
		local i=""
		for ref in "${refs[@]}"; do # parse line references and find the largest one
			(( i = i>ref ? i : ref ))
		done

		# unzip base string on largest reference found --> all references with this number will be in string
		local unzipped=($(echo "$base" | sed "s/#$i/\\$newline/g")) 
		local new_base=""
		if [ -z "$unzipped" ]; then new_base="${!i}"; fi
		for (( j=i,i=0; i<${#unzipped[@]}-1; j++,i++ )); do
			new_base="${new_base}${unzipped[i]}${!j}" # alternate string fragments and referenced strings
		done
		new_base="${new_base}${unzipped[i]}" # append the last part of base string
	done
	IFS="$SAVE_IFS"
	echo "$new_base" 

}

function load_json_2 () { # unpack json into global array -- $1: file path -- $load_json_2_out: (global) array output
	local SAVE_IFS="$IFS"
	IFS=$'\n' # change the IFS to newline so we can parse unpacking output properly
	local base=""
	local result="$(cat "$1")" # read the input file
	local i=0

	local layer=()
	local master_index=0
	while ! [ "$base" == "$result" ]; do # unpack until there is no nesting left in the base string
		local base="$result"		
		local layer=($(get_nested "$base")) # extract all braces containing no nested braces ie leaf nodes
		((i=${#load_json_master[@]}+2))
		local result=$(replace_nested "$base" "$i") # replace all leaf nodes values with the index we will start writing to
		for (( j=0; j<${#layer[@]}; j++,master_index++ )); do
			load_json_master[master_index]="${layer[j]}" # write leaf nod values to master array
		done
	done
	IFS="$SAVE_IFS"

}

function write_json_stack_2 () { # write a generated json stack to a file -- $1: file path -- $2...: array entries
	local i="2"
	# retrieve the JSON source string by repacking given array
	echo "SOURCE ----- $(repack_nested "${@: -1}" "${@:2}")" > "$1" # find the array base and do a recursive expand
	while [[ $i -lt $# ]]; do # write the array index-by-index to the file
		echo "${!i}" >> "$1"
		((i++))
	done
	echo "${!i}" >> "$1"
}

function get_base () { # retrieve a field value base from a keychain and unrolled array
	# $1: size of unrolled array
	# $2...: unrolled json array
	# $...n...: keychain
	local keychain=""; ((keychain=$1+2)) # start of keychain
	local base=""; ((base=keychain-1)); local field="${!base}" # base of unrolled json --> start traversal here
	local key_path=""
	for key in "${@:keychain}"; do # traverse unrolled array via keys and line references
		key_path="${key_path}${key} --> " # track the keychain in case of key errors
		# check key type
		if [[ "$key" =~ ^[0-9]+$ ]]; then # key is an array index
			# match CSV fields until we reach the desired index
			# then strip off remaining CSV fields and outer brackets
			field=$(echo "$field" | sed -E "s/(\"[^\"]+\"[],]|[0-9.-]+[],]|#[0-9]+[],]){$key}//" | sed -E 's/\[([^\,]*),?.*\]/\1/')
			
			# check the result: anything that still has some sort of bracket indicates an invalid key
			if [ "$field" == "[" ]; then echo "Error: Array index [$key] out of bounds"; echo "Keychain: ${key_path}[ERROR]"; return 1; fi
			if [ "${field:0:1}" == "{" ]; then echo "Error: Indexing into non-array"; echo "Keychain: ${key_path}[ERROR]"; return 1; fi
		else # key is a field name
			# strip out everything except the field following the given key
			field=$(echo "$field" | sed -E "s/.*\"$key\": *\"?([^\"]+)\"?[]},].*/\1/")

			# check the result: anything still in curly braces was indicates an invalid key
			if [ "${field:0:1}" == "{" ]; then echo "KeyError: [$key] not found"; echo "Keychain: ${key_path}[ERROR]"; return 1; fi
		fi
		if [ "${field:0:1}" == "#" ]; then # found a reference, do a shallow repack and keep going
			local ref="${field:1}" # extract array index following pound#
			field="${!ref}" # load extracted index only, no further expansion
		fi
	done
	# passing no keys expands the array base and returns the entire json string
	# recursively expand the field found and echo the fully packed result
	# repack_nested "$field" "${load_json_master[@]}"

	echo "$field"	

}

function get_item_2 () { # retrieve a full field value from a keychain and unrolled array
	# $1: size of unrolled array
	# $2...: unrolled json array
	# $...n...: keychain
	repack_nested "$(get_base "$@")" "${@:2}"
}

function get_keys () { # retrieve a list of keys avalable from a given keychain and unrolled array
	echo "keys: $(get_base "$@" | sed -E 's/{?"([^"]+)":\"?[^\"]+\"?[]},]/\1, /g' | sed 's/, $//')"
}


echo "$(date -u "+%Y - %m - %d T %H : %M : %S")" > "test_out.txt"

load_json_2 "$1"
echo "done loading"

((master_index=${#load_json_master[@]}))

write_json_stack_2 "test_out.txt" "${load_json_master[@]}"
echo "done writing"

get_item_2 "$master_index" "${load_json_master[@]}" "${@:2}"
echo "done getting"

get_keys "$master_index" "${load_json_master[@]}" "${@:2}"
echo "got keys"



