#include "kexecute.h"
#include "ubc_headers.h"
#include "patchfinder64.h"
#include "kmem.h"
#include "osobject.h"
#include <stdlib.h>
#include <stddef.h>
#include "cs_blobs.h"
#include <Foundation/Foundation.h>

uint64_t get_vfs_context() {
    // vfs_context_t vfs_context_current(void)
    uint64_t vfs_context = kexecute(find_vfs_context_current(), 1, NULL, NULL, NULL, NULL, NULL, NULL);
    vfs_context = zm_fix_addr(vfs_context);
    return vfs_context;
}

int get_vnode_fromfd(uint64_t vfs_context, int fd, uint64_t *vpp) {
    uint64_t vnode = kalloc(sizeof(vnode_t *));
    
    // int vnode_getfromfd(vfs_context_t cfx, int fd, vnode_t vpp)
    int ret = kexecute(find_vnode_getfromfd(), vfs_context, fd, vnode, NULL, NULL, NULL, NULL);
    if (ret != 0) {
        return -1;
    }
    
    *vpp = vnode;
    return 0;
}

int check_vtype(uint64_t vnode) {
    /*
         struct vnode { // `vnode`
            ...
            uint16_t `v_type`;
     */
    uint16_t v_type = rk64(vnode + offsetof(struct vnode, v_type));
    return (v_type == VREG) ? 1 : 0;
}

uint64_t get_vu_ubcinfo(uint64_t vnode) {
    /*
         struct vnode { // `vnode`
            ...
            union {
                struct ubc_info *vu_ubcinfo;
            } v_un;
     */
    return rk64(vnode + offsetof(struct vnode, v_un));
}

uint64_t get_csblobs(uint64_t vu_ubcinfo) {
    /*
         struct ubc_info { // `vu_ubcinfo`
            ....
            struct cs_blob *cs_blobs;
     */
    return rk64(vu_ubcinfo + offsetof(struct ubc_info, cs_blobs));
}

uint64_t get_csb_entitlements(uint64_t cs_blobs) {
    return rk64(cs_blobs + offsetof(struct cs_blob, csb_entitlements));
}

void csblob_ent_dict_set(uint64_t cs_blobs, uint64_t dict) {
    // void csblob_entitlements_dictionary_set(struct cs_blob *csblob, void *entitlements)
    kexecute(find_csblob_ent_dict_set(), cs_blobs, dict, NULL, NULL, NULL, NULL, NULL);
}

int csblob_get_ents(uint64_t cs_blob, CS_GenericBlob *ent_blob) {
    uint64_t out_start_ptr = kalloc(sizeof(void **));
    uint64_t out_length_ptr = kalloc(sizeof(size_t));
    int ret = kexecute(find_csblob_get_ents(), cs_blob, out_start_ptr, out_length_ptr, NULL, NULL, NULL, NULL);
    if (ret != 0) {
        return -1;
    }
    
    int out_length = rk64(out_length_ptr);
    if (out_length == 0) {
        return out_length;
    }
    
    uint64_t out_start = rk64(out_start_ptr);
    
    // read CS_GenericBlob (there may be a better way to do this,
    // but `kread` can get hung up on null bytes - eg in `length`
    uint32_t magic = rk32(out_start);
    uint32_t length = rk32(out_start + 4);
    char *dict_str = malloc(length);
    kread(out_start + 8, dict_str, length);
    
    *ent_blob = (CS_GenericBlob) {
        magic,
        length
    };
    
    strncpy(ent_blob->data, dict_str, length);
    
    return out_length;
}

int fixup_platform_application(const char *path) {
    int ret;
    
    uint64_t vfs_context = get_vfs_context();
    if (vfs_context == 0) {
        return -1;
    }
    
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return -2;
    }
    
    uint64_t *vpp = malloc(sizeof(vnode_t *));
    ret = get_vnode_fromfd(vfs_context, fd, vpp);
    if (ret != 0) {
        return -3;
    }
    
    uint64_t vnode = rk64(*vpp);
    if (vnode == 0) {
        return -4;
    }
    
    ret = check_vtype(vnode);
    if (ret != 0) {
        return -5;
    }
    
    uint64_t vu_ubcinfo = get_vu_ubcinfo(vnode);
    if (vu_ubcinfo == 0) {
        return -6;
    }
    
    uint64_t cs_blobs = get_csblobs(vu_ubcinfo);
    if (cs_blobs == 0) {
        return -7;
    }
    
    uint64_t csb_entitlements = get_csb_entitlements(cs_blobs);
    if (csb_entitlements != 0) {
        return -8;
    }
    
    CS_GenericBlob *generic_blob = malloc(sizeof(CS_GenericBlob));
    ret = csblob_get_ents(cs_blobs, generic_blob);
    if (ret == -1) {
        return -9;
    }
    
    // no entitlements at all, let's add some (or.. one)
    if (ret == 0) {
        uint64_t dict = OSUnserializeXML("<dict></dict>"); // empty dict
        
        // add platform application & set it to true
        ret = OSDictionary_SetItem(dict, "platform-application", find_OSBoolean_True());
        if (ret != 0) {
            return -10;
        }
        
        csblob_ent_dict_set(cs_blobs, dict);
        return 0;
    }
    
    // construct an OSDict with OSUnser. & the parsed blob
    uint64_t dict = OSUnserializeXML(generic_blob->data);
    if (dict == 0) {
        return -11;
    }
    
    // look for platform application
    uint64_t plat_appl = OSDictionary_GetItem(dict, "platform-application");
    if (plat_appl == 0) {
        // already has platform application - nothing to do here
        return 0;
    }
    
    // add it in
    ret = OSDictionary_SetItem(dict, "platform-application", find_OSBoolean_True());
    if (ret != 0) {
        return -11;
    }
    
    csblob_ent_dict_set(cs_blobs, dict);
    
    return 0;
}
